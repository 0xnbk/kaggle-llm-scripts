#!/usr/bin/env python3
"""Loopback Ollama bridge that keeps quiet OpenAI SSE responses alive."""

import argparse
import asyncio
import json
import re
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientSession, ClientTimeout, web


HEALTH_PATH = "/_kaggle/stream-proxy/health"
MAX_EVENT_BYTES = 16 * 1024 * 1024
EVENT_END = re.compile(rb"\r\n\r\n|\n\n|\r\r")
HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host",
}
UPSTREAM = web.AppKey("upstream", str)
HEARTBEAT = web.AppKey("heartbeat_seconds", float)
CLIENT = web.AppKey("client", ClientSession)


@web.middleware
async def loopback_host(request: web.Request, handler):
    try:
        host = urlsplit("//" + request.headers.get("Host", ""))
        allowed = (
            host.hostname in ("localhost", "127.0.0.1", "::1")
            and not host.username and not host.password
            and not host.path and not host.query and not host.fragment
        )
        if host.port is not None and not 0 < host.port <= 65535:
            allowed = False
    except ValueError:
        allowed = False
    if not allowed:
        return web.Response(status=403)
    return await handler(request)


def forwarded_headers(headers, *, upstream: bool = False) -> list[tuple[str, str]]:
    excluded = HOP_HEADERS | {name.strip().lower() for name in headers.get("Connection", "").split(",")}
    if upstream:
        excluded |= {"cf-access-client-id", "cf-access-client-secret", "cookie", "accept-encoding"}
    result = [(name, value) for name, value in headers.items() if name.lower() not in excluded]
    if upstream:
        result.append(("Accept-Encoding", "identity"))
    return result


def stream_error(message: str, code: str) -> bytes:
    payload = {"error": {"message": message, "type": "upstream_error", "param": None, "code": code}}
    return b"data: " + json.dumps(payload).encode() + b"\n\n"


async def relay_sse(request: web.Request, body: bytes) -> web.StreamResponse:
    response = web.StreamResponse(headers={
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache, no-transform",
        "X-Accel-Buffering": "no",
    })
    await response.prepare(request)
    await response.write(b": connected\n\n")
    write_lock = asyncio.Lock()

    async def emit(event: bytes) -> None:
        async with write_lock:
            await response.write(event)

    async def heartbeat() -> None:
        while True:
            await asyncio.sleep(request.app[HEARTBEAT])
            await emit(b": keepalive\n\n")

    async def relay() -> None:
        session = request.app[CLIENT]
        try:
            async with session.request(
                request.method, request.app[UPSTREAM] + request.raw_path,
                data=body, headers=forwarded_headers(request.headers, upstream=True),
                allow_redirects=False,
            ) as upstream:
                if upstream.status != 200:
                    await emit(stream_error(f"Ollama returned HTTP {upstream.status}.", f"http_{upstream.status}"))
                    return
                if "text/event-stream" not in upstream.headers.get("Content-Type", "").lower():
                    await emit(stream_error("Ollama did not return an SSE response.", "invalid_content_type"))
                    return
                pending = bytearray()
                async for chunk in upstream.content.iter_any():
                    pending.extend(chunk)
                    while match := EVENT_END.search(pending):
                        if match.end() > MAX_EVENT_BYTES:
                            await emit(stream_error("Ollama SSE event exceeded the size limit.", "event_too_large"))
                            return
                        event = bytes(pending[:match.end()])
                        del pending[:match.end()]
                        await emit(event)
                    if len(pending) > MAX_EVENT_BYTES:
                        await emit(stream_error("Ollama SSE event exceeded the size limit.", "event_too_large"))
                        return
                if pending:
                    await emit(stream_error("Ollama closed the stream during an incomplete SSE event.", "incomplete_event"))
        except (ClientError, asyncio.TimeoutError) as exc:
            await emit(stream_error(f"Ollama stream failed ({type(exc).__name__}).", "upstream_connection_error"))

    tasks = [asyncio.create_task(relay()), asyncio.create_task(heartbeat())]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            await task
        await response.write_eof()
    except (ConnectionResetError, ClientError):
        pass
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    return response


async def forward(request: web.Request) -> web.StreamResponse:
    if request.headers.get("Content-Encoding", "identity").lower() not in ("", "identity"):
        return web.json_response({"error": "Compressed request bodies are unsupported; set provider encoding to none."}, status=415)
    body = await request.read()
    is_sse = False
    if request.method == "POST" and request.path.rstrip("/") == "/v1/chat/completions":
        try:
            is_sse = json.loads(body).get("stream") is True
        except (ValueError, AttributeError):
            pass
    if is_sse:
        return await relay_sse(request, body)
    response = None
    try:
        async with request.app[CLIENT].request(
            request.method, request.app[UPSTREAM] + request.raw_path,
            data=body or None, headers=forwarded_headers(request.headers, upstream=True),
            allow_redirects=False,
        ) as upstream:
            response = web.StreamResponse(status=upstream.status, headers=forwarded_headers(upstream.headers))
            await response.prepare(request)
            async for chunk in upstream.content.iter_any():
                await response.write(chunk)
            await response.write_eof()
            return response
    except (ClientError, asyncio.TimeoutError):
        if response is not None and response.prepared:
            raise
        return web.json_response({"error": "Could not reach the local Ollama server."}, status=502)


def create_app(upstream_port: int = 11435, heartbeat_seconds: float = 10) -> web.Application:
    app = web.Application(client_max_size=32 * 1024 * 1024, middlewares=[loopback_host])
    app[UPSTREAM] = f"http://127.0.0.1:{upstream_port}"
    app[HEARTBEAT] = heartbeat_seconds

    async def client_lifecycle(app):
        async with ClientSession(
            timeout=ClientTimeout(total=None, connect=10, sock_read=1800),
            auto_decompress=False, trust_env=False,
        ) as client:
            app[CLIENT] = client
            yield

    async def health(_request):
        return web.json_response({"service": "ollama-stream-proxy", "upstream_port": upstream_port})

    app.cleanup_ctx.append(client_lifecycle)
    app.router.add_get(HEALTH_PATH, health)
    app.router.add_route("*", "/{path:.*}", forward)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-port", type=int, default=11434)
    parser.add_argument("--upstream-port", type=int, default=11435)
    args = parser.parse_args()
    web.run_app(
        create_app(args.upstream_port), host="127.0.0.1", port=args.listen_port,
        access_log=None, print=None, handler_cancellation=True, shutdown_timeout=5,
    )
