"""Loopback Messages fixture for complete native-game capture/parity checks."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "complete"


class Provider(BaseHTTPRequestHandler):
    calls = 0

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/v1/messages"
        assert self.headers["X-Coworld-Player-Slot"] == "0"
        assert [m["role"] for m in request["messages"]] == ["user"]
        Provider.calls += 1
        if MODE == "provider_error":
            body = json.dumps(
                {"type": "error", "error": {"type": "api_error", "message": "upstream 500"}}
            ).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header(
                "x-softmax-llm-call-id",
                f"00000000-0000-4000-8000-{Provider.calls:012d}",
            )
            self.end_headers()
            self.wfile.write(body)
            return
        if MODE == "reject":
            text = '{"actions":[{"act":"invalid-command"}]}'
        else:
            text = '{"actions":[{"act":"noop"}],"say":"","notes":"PRIVATE_CAPTURE_SENTINEL"}'
            if Provider.calls == 2:
                text = "```json\n" + text + "\n```"
        body = json.dumps(
            {
                "model": "native-capture-fixture",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 10, "output_tokens": 5},
                "content": [{"type": "text", "text": text}],
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("x-softmax-llm-call-id", f"00000000-0000-4000-8000-{Provider.calls:012d}")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Provider)
    print(server.server_port, flush=True)
    server.serve_forever()
