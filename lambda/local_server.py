"""
MoodMuse local development server — stdlib only, no extra dependencies.

Listens on localhost:8000 and routes requests through lambda_handler()
using the same API Gateway HTTP API v2 event shape that the real Lambda
receives. The frontend never needs to know it is talking to a local server.

Usage:
    cd /path/to/moodmuse/lambda
    python local_server.py

Then open frontend/index.html in your browser (file:// is fine).
MOCK_MODE defaults to true in handler.py, so no AWS credentials are needed.

To test the real Bedrock path locally (requires valid AWS credentials):
    MOCK_MODE=false python local_server.py
"""

import http.server
import json
import sys
import os

# ── Make sure handler.py is importable when running from the lambda/ dir ───────
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import handler  # noqa: E402 — intentional late import after path fix

HOST = "localhost"
PORT = 8000


class MoodMuseHandler(http.server.BaseHTTPRequestHandler):
    """
    Handles POST /generate and OPTIONS /generate.
    Everything else returns 404.
    """

    # Silence the default per-request access log line so output stays readable.
    def log_message(self, format, *args):  # noqa: A002
        print(f"[local_server] {self.address_string()} — {format % args}")

    # ── OPTIONS preflight ──────────────────────────────────────────────────────
    def do_OPTIONS(self):
        event = self._build_event("OPTIONS", b"")
        self._dispatch(event)

    # ── POST ───────────────────────────────────────────────────────────────────
    def do_POST(self):
        if self.path != "/generate":
            self._send_raw(404, {"error": "Not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length) if length > 0 else b""
        event = self._build_event("POST", body_bytes)
        self._dispatch(event)

    # ── Helpers ────────────────────────────────────────────────────────────────

    def _build_event(self, method: str, body_bytes: bytes) -> dict:
        """
        Constructs a minimal API Gateway HTTP API v2 proxy event dict.
        This is the exact shape lambda_handler() expects:
          event["requestContext"]["http"]["method"]  → method routing
          event["body"]                              → JSON string
        """
        return {
            "version": "2.0",
            "routeKey": f"{method} /generate",
            "rawPath": "/generate",
            "requestContext": {
                "http": {
                    "method": method,
                    "path": "/generate",
                    "protocol": "HTTP/1.1",
                    "sourceIp": "127.0.0.1",
                    "userAgent": self.headers.get("User-Agent", "local"),
                }
            },
            "headers": {
                "content-type": self.headers.get("Content-Type", "application/json"),
            },
            # Lambda handler expects body as a string (API GW sends it that way)
            "body": body_bytes.decode("utf-8") if body_bytes else None,
            "isBase64Encoded": False,
        }

    def _dispatch(self, event: dict):
        """
        Calls lambda_handler with the constructed event, then writes the
        exact response (status, headers, body) back to the HTTP client.
        The response shape is identical to what API Gateway would return,
        so the frontend code never needs to change.
        """
        result = handler.lambda_handler(event, context=None)

        status_code = result.get("statusCode", 200)
        headers     = result.get("headers", {})
        body        = result.get("body", "")

        self._send_raw(status_code, body, extra_headers=headers)

    def _send_raw(self, status_code: int, body, extra_headers: dict = None):
        """
        Writes the HTTP response. body can be a dict (will be JSON-encoded)
        or a string (sent as-is). extra_headers are written before the body.
        """
        if isinstance(body, dict):
            body = json.dumps(body)

        body_bytes = body.encode("utf-8") if isinstance(body, str) else body

        self.send_response(status_code)

        # Write caller-supplied headers first (CORS headers from handler, etc.)
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)

        # Ensure Content-Length is always present so browsers don't hang
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()

        if body_bytes:
            self.wfile.write(body_bytes)


def main():
    mock_status = os.environ.get("MOCK_MODE", "true").lower()
    print(f"")
    print(f"  MoodMuse local server")
    print(f"  ─────────────────────────────────────────")
    print(f"  Listening : http://{HOST}:{PORT}")
    print(f"  MOCK_MODE : {mock_status}  {'(no AWS credentials needed)' if mock_status == 'true' else '(will call real Bedrock)'}")
    print(f"  Route     : POST http://{HOST}:{PORT}/generate")
    print(f"")
    print(f"  Open frontend/index.html in your browser to use the app.")
    print(f"  Press Ctrl+C to stop.")
    print(f"")

    server = http.server.HTTPServer((HOST, PORT), MoodMuseHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Server stopped.")
        server.server_close()


if __name__ == "__main__":
    main()
