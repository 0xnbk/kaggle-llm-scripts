import asyncio
import gzip
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

from aiohttp import ClientSession, ClientTimeout, web
from aiohttp.test_utils import TestClient, TestServer


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/kaggle/ollama-stream-proxy.py"
SPEC = importlib.util.spec_from_file_location("ollama_stream_proxy", SCRIPT)
PROXY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROXY)


class StreamProxyTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.requests = []
        self.handler = None

        async def upstream(request):
            body = await request.read()
            self.requests.append((request.method, request.path, request.headers.copy(), body))
            return await self.handler(request)

        app = web.Application()
        app.router.add_route("*", "/{path:.*}", upstream)
        self.upstream = TestServer(app, handler_cancellation=True)
        await self.upstream.start_server()
        app = PROXY.create_app(self.upstream.port, heartbeat_seconds=0.02)
        self.proxy = TestServer(app, handler_cancellation=True)
        self.client = TestClient(self.proxy)
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.upstream.close()

    async def stream(self):
        return await self.client.post("/v1/chat/completions", json={
            "model": "qwen3.8:27b", "messages": [{"role": "user", "content": "test"}], "stream": True,
        })

    async def test_heartbeats_cover_silence_before_upstream_headers(self):
        async def handler(request):
            await asyncio.sleep(0.18)
            return web.Response(body=b"data: [DONE]\n\n", content_type="text/event-stream")

        self.handler = handler
        async with ClientSession(timeout=ClientTimeout(total=2, sock_read=0.07)) as client:
            with self.assertRaises(asyncio.TimeoutError):
                async with client.post(self.upstream.make_url("/v1/chat/completions"), json={"stream": True}):
                    pass
            async with client.post(self.proxy.make_url("/v1/chat/completions"), json={"stream": True}) as response:
                body = await response.read()
        self.assertIn(b": keepalive\n\n", body)
        self.assertTrue(body.endswith(b"data: [DONE]\n\n"))
        self.assertEqual(len(self.requests), 2)  # One direct control, one proxied request; no retries.

    async def test_heartbeats_never_split_a_tool_call_or_unicode(self):
        document = {"choices": [{"delta": {"tool_calls": [{"function": {
            "name": "write_file", "arguments": json.dumps({"content": "align \U0001f600"}, ensure_ascii=False),
        }}]}}]}
        event = b"data: " + json.dumps(document, ensure_ascii=False).encode() + b"\n\n"
        cut = event.index("\U0001f600".encode()) + 1

        async def handler(request):
            response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await response.prepare(request)
            await response.write(event[:cut])
            await asyncio.sleep(0.09)
            await response.write(event[cut:] + b"data: [DONE]\n\n")
            return response

        self.handler = handler
        response = await self.stream()
        body = await response.read()
        self.assertIn(event, body)
        self.assertIn(b": keepalive\n\n", body)
        data = [line[6:] for line in body.splitlines() if line.startswith(b"data: ")]
        self.assertEqual(json.loads(data[0]), document)
        self.assertEqual(data[1], b"[DONE]")

    async def test_crlf_events_are_preserved(self):
        event = b'data: {"choices":[]}\r\n\r\ndata: [DONE]\r\n\r\n'

        async def handler(request):
            return web.Response(body=event, content_type="text/event-stream")

        self.handler = handler
        response = await self.stream()
        self.assertTrue((await response.read()).endswith(event))

    async def test_native_ndjson_and_request_body_are_unchanged(self):
        payload = {"model": "qwen3.8:27b", "prompt": "QWEN_OK", "stream": True}
        expected = b'{"response":"QWEN_OK","done":true}\n'

        async def handler(request):
            return web.Response(body=expected, content_type="application/x-ndjson")

        self.handler = handler
        response = await self.client.post("/api/generate", json=payload, headers={
            "CF-Access-Client-Id": "do-not-forward", "CF-Access-Client-Secret": "do-not-forward",
            "Cookie": "do-not-forward", "Host": "localhost:11434",
        })
        self.assertEqual(await response.read(), expected)
        self.assertEqual(json.loads(self.requests[0][3]), payload)
        headers = self.requests[0][2]
        self.assertNotIn("CF-Access-Client-Secret", headers)
        self.assertNotIn("Cookie", headers)
        self.assertTrue(headers["Host"].startswith("127.0.0.1:"))

    async def test_nonstream_error_status_is_preserved(self):
        async def handler(request):
            return web.json_response({"error": "model missing"}, status=404)

        self.handler = handler
        response = await self.client.post("/v1/chat/completions", json={"stream": False})
        self.assertEqual(response.status, 404)
        self.assertEqual(await response.json(), {"error": "model missing"})

    async def test_stream_error_is_explicit_without_fabricating_completion(self):
        async def handler(request):
            return web.json_response({"error": "model missing"}, status=404)

        self.handler = handler
        response = await self.stream()
        body = await response.read()
        data = next(line[6:] for line in body.splitlines() if line.startswith(b"data: "))
        self.assertEqual(json.loads(data)["error"]["code"], "http_404")
        self.assertNotIn(b"[DONE]", body)

    async def test_truncated_sse_event_is_reported(self):
        async def handler(request):
            return web.Response(body=b'data: {"partial":', content_type="text/event-stream")

        self.handler = handler
        response = await self.stream()
        body = await response.read()
        self.assertIn(b'"code": "incomplete_event"', body)
        self.assertNotIn(b"[DONE]", body)

    async def test_client_disconnect_cancels_upstream_generation(self):
        began = asyncio.Event()
        cancelled = asyncio.Event()

        async def handler(request):
            began.set()
            try:
                await asyncio.sleep(30)
                return web.Response()
            finally:
                cancelled.set()

        self.handler = handler
        response = await self.stream()
        await asyncio.wait_for(began.wait(), 1)
        response.close()
        await asyncio.wait_for(cancelled.wait(), 1)

    async def test_health_does_not_contact_ollama(self):
        response = await self.client.get(PROXY.HEALTH_PATH)
        self.assertEqual((await response.json())["service"], "ollama-stream-proxy")
        self.assertEqual(self.requests, [])

    async def test_public_or_malformed_hosts_are_rejected(self):
        for host in ("llm.example.com", "localhost.attacker.example", "attacker@localhost", "localhost:invalid", "localhost/path"):
            with self.subTest(host=host):
                response = await self.client.get(PROXY.HEALTH_PATH, headers={"Host": host})
                self.assertEqual(response.status, 403)
        self.assertEqual(self.requests, [])

    async def test_compressed_requests_are_rejected_explicitly(self):
        response = await self.client.post("/api/generate", data=gzip.compress(b"{}"), headers={"Content-Encoding": "gzip"})
        self.assertEqual(response.status, 415)
        self.assertEqual(self.requests, [])

    async def test_large_event_is_bounded(self):
        async def handler(request):
            return web.Response(body=b"data: " + b"x" * 80 + b"\n\n", content_type="text/event-stream")

        self.handler = handler
        with mock.patch.object(PROXY, "MAX_EVENT_BYTES", 32):
            response = await self.stream()
            body = await response.read()
        self.assertIn(b'"code": "event_too_large"', body)
        self.assertNotIn(b"[DONE]", body)


if __name__ == "__main__":
    unittest.main()
