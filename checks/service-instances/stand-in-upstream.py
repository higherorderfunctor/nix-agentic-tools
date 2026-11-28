# Stand-in for ./module-eval.nix. Answer chat completions and Anthropic
# messages with this upstream's name. Codex Responses must reach the chat
# path, not a native Responses endpoint. Log each POST's path and authorization
# so the caller detects a wrong endpoint, credential, or extra upstream call.
# A GET answers 200 for readiness. Arguments: name, port, log path.
import http.server
import json
import sys

NAME, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]


def chat_completion():
    return {
        "choices": [
            {
                "finish_reason": "stop",
                "index": 0,
                "message": {"content": NAME, "role": "assistant"},
            }
        ],
        "created": 0,
        "id": "chatcmpl-" + NAME,
        "model": "shared-model",
        "object": "chat.completion",
        "usage": {"completion_tokens": 1, "prompt_tokens": 1, "total_tokens": 2},
    }


def message():
    return {
        "content": [{"text": NAME, "type": "text"}],
        "id": "msg_" + NAME,
        "model": "claude-shared",
        "role": "assistant",
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "type": "message",
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Readiness only; a GET reaches no log.
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(LOG, "a") as handle:
            handle.write(f"{self.path} {self.headers.get('Authorization')}\n")
        path = self.path.split("?", 1)[0]
        if path == "/v1/messages":
            reply = message()
        elif path == "/v1/chat/completions":
            reply = chat_completion()
        else:
            self.send_error(404, "stand-in upstream only serves documented API paths")
            return
        body = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Upstream).serve_forever()
