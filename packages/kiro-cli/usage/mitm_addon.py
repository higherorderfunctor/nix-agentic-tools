"""Load with mitmdump -s /absolute/path/mitm_addon.py; no mitmproxy import required."""

import base64
import binascii
import os
import re
import sqlite3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from capture import CaptureCapacityError, Collector

# Workflow steps and subagents call GenerateAssistantResponse; root turns call CreateResponse.
APIS = {"/generateAssistantResponse": "generate_assistant_response", "/v1/responses": "create_response"}


class UsageCapture:
    def load(self, loader):
        self.active, self.collector, self.failed = {}, None, True
        self.invocations = {}
        try:
            self.collector = Collector(os.environ["KIRO_USAGE_DB"], max_stored_bytes=int(os.environ.get("KIRO_USAGE_MAX_BYTES", "268435456")))
        except (KeyError, OSError, RuntimeError, TypeError, ValueError, sqlite3.Error):
            print("Kiro usage capture startup failed: selected requests will be refused; fix capture configuration and restart", file=sys.stderr)
        else:
            self.failed = False

    def _invocation(self, flow):
        # Proxy credentials are local correlation only, never provider auth.
        authorization = getattr(flow.request, "headers", {}).pop("proxy-authorization", "")
        try:
            scheme, encoded = authorization.split(" ", 1)
            decoded = base64.b64decode(encoded, validate=True).decode("ascii")
        except (ValueError, UnicodeError, binascii.Error):
            return
        match = re.fullmatch(r"kiro-usage-([0-9a-f]{32}):", decoded)
        if scheme.lower() == "basic" and match:
            self.invocations[flow.client_conn.id] = match[1]

    def http_connect(self, flow):
        self._invocation(flow)

    def client_disconnected(self, client):
        self.invocations.pop(client.id, None)

    def request(self, flow):
        self._invocation(flow)
        host = flow.request.host.lower()
        if not (host == "kiro.dev" or host.endswith(".kiro.dev")):
            return
        path = flow.request.path.split("?", 1)[0]
        if path not in APIS:
            return
        if self.failed:
            self._reject(flow)
            return
        # Never copy URLs, query strings, cookies, or authentication headers.
        metadata = {"api": APIS[path], "host": host, "method": flow.request.method, "path": path}
        # Non-secret routing headers; a body conversationState.conversationId takes precedence.
        for header, key in (("x-amzn-kiro-agent-mode", "agent_mode"), ("x-amzn-kiro-conversation-id", "kiro:conversation_id")):
            value = flow.request.headers.get(header)
            if value is not None:
                metadata[key] = value
        client = getattr(flow, "client_conn", None)
        invocation = self.invocations.get(client.id) if client else None
        if invocation:
            metadata["invocation"] = invocation
        try:
            body = flow.request.get_content(strict=True)
        except ValueError:
            self._reject(flow, status=400, message=b"Cannot decode selected Kiro request body")
            return
        metadata["request_content_encoding"] = flow.request.headers.get("content-encoding", "identity")
        try:
            if self.failed:
                raise RuntimeError("capture failed")
            self.active[flow.id] = self.collector.begin(metadata, body or b"")
        except CaptureCapacityError:
            self._reject(flow, message=b"Kiro usage capture at capacity; retry after active requests finish")
        except RuntimeError:
            self._failed()
            self._reject(flow)

    def _failed(self):
        if not self.failed:
            print("Kiro usage capture failed: existing responses pass through; new selected requests are refused until restart", file=sys.stderr)
        self.failed = True

    def _reject(self, flow, status=503, message=b"Kiro usage capture unavailable; restart the capture service"):
        from mitmproxy import http
        flow.response = http.Response.make(status, message, {"Content-Type": "text/plain"})

    def responseheaders(self, flow):
        ident = self.active.get(flow.id)
        if not ident:
            return
        metadata = {"status": flow.response.status_code}
        for header, key in (("content-encoding", "content_encoding"), ("content-type", "content_type"), ("x-amzn-requestid", "upstream_request_id"), ("x-request-id", "request_id")):
            value = flow.response.headers.get(header)
            if value is not None:
                metadata[key] = value
        try:
            self.collector.headers(ident, metadata)
        except RuntimeError:
            self._failed()
        def stream(data):
            if not self.failed:
                try:
                    self.collector.check()
                    if data:
                        self.collector.chunk(ident, data)
                except RuntimeError:
                    self._failed()
            return data  # Including b"": return the original object immediately.
        flow.response.stream = stream

    def response(self, flow):
        ident = self.active.pop(flow.id, None)
        self._finish(ident)

    def error(self, flow):
        ident = self.active.pop(flow.id, None)
        self._finish(ident, transport_ended=False, error="transport_error")

    def _finish(self, ident, **options):
        if ident and not self.failed:
            try:
                self.collector.finish(ident, **options)
            except RuntimeError:
                self._failed()

    def done(self):
        if self.collector is not None:
            self.collector.close()


addons = [UsageCapture()]
