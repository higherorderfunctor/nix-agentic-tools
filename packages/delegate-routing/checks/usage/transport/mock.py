"""The offline binding check records each CPA request and returns one scripted HTTP reply."""

from collections.abc import Iterator
import json

from pydantic import JsonValue

from usage.transport import HttpRequest, HttpResponse


class RecordingTransport:
    """Keep complete requests, decoding their JSON bodies for structural comparisons."""

    def __init__(self, replies: Iterator[tuple[int, JsonValue]]):
        self.replies = replies
        self.requests: list[dict[str, object]] = []

    def request(self, request: HttpRequest) -> HttpResponse:
        """Expose exactly the vendor payload that would reach the management transport."""
        record = request.model_dump(mode="json")
        if request.body is not None:
            record["body"] = json.loads(request.body)
        self.requests.append(record)
        status, body = next(self.replies)
        return HttpResponse(status_code=status, body=json.dumps(body)).checked()
