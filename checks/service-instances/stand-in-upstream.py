# A stand-in upstream for ./module-eval.nix: it answers every OpenAI chat
# completion, every Anthropic message (a path under /v1/messages) and every
# OpenAI response (a path ending in /responses, which CLIProxyAPI's codex
# executor always streams) with its own name, and appends
# "<path> <authorization>" to its log, so the check can tell which upstream a
# client key reached. A GET answers 200 for readiness. Arguments: name, port,
# log path.
import http.server
import json
import sys
import time
from pathlib import Path

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


def response_events():
    item = {
        "content": [{"annotations": [], "text": NAME, "type": "output_text"}],
        "id": "msg_" + NAME,
        "role": "assistant",
        "status": "completed",
        "type": "message",
    }
    response = {
        "created_at": 0,
        "id": "resp_" + NAME,
        "model": "shared-model",
        "object": "response",
        "output": [item],
        "status": "completed",
        "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
    }
    events = [
        {"content_index": 0, "delta": NAME, "item_id": item["id"], "output_index": 0, "type": "response.output_text.delta"},
        {"item": item, "output_index": 0, "type": "response.output_item.done"},
        {"response": response, "type": "response.completed"},
    ]
    return "".join(
        f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events
    ).encode()


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Readiness only; a GET reaches no log.
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        done = Path(LOG + ".done")
        done.unlink(missing_ok=True)
        with open(LOG, "a") as handle:
            handle.write(f"{self.path} {self.headers.get('Authorization')}\n")
        if self.path.split("?")[0].endswith("/responses"):
            body, kind = response_events(), "text/event-stream"
        elif self.path.startswith("/v1/messages"):
            body, kind = json.dumps(message()).encode(), "application/json"
        else:
            body, kind = json.dumps(chat_completion()).encode(), "application/json"
        if request.get("stream") and self.path.startswith("/v1/messages"):
            events = [
                {"type": "message_start", "message": message() | {"content": [], "stop_reason": None}},
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": NAME}},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}},
                {"type": "message_stop"},
            ]
            body = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
            kind = "text/event-stream"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if request.get("stream"):
            events = [event for event in body.split(b"\n\n") if event]
            for index, event in enumerate(events):
                # Mark BEFORE sending the final event: a buffered client must
                # never pass the assertion merely by beating cleanup afterward.
                if index == len(events) - 1:
                    done.touch()
                self.wfile.write(event + b"\n\n")
                self.wfile.flush()
                time.sleep(0.2)
        else:
            self.wfile.write(body)
            done.touch()

    def log_message(self, *_):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Upstream).serve_forever()
