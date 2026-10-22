# A stand-in upstream for ./module-eval.nix: it answers every OpenAI chat
# completion with its own name and appends "<path> <authorization>" to its
# log, so the check
# can tell which upstream a client key reached. A GET answers 200 for
# readiness. Arguments: name, port, log path.
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



class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Readiness only; a GET reaches no log.
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(LOG, "a") as handle:
            handle.write(f"{self.path} {self.headers.get('Authorization')}\n")
        body = json.dumps(chat_completion()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Upstream).serve_forever()
