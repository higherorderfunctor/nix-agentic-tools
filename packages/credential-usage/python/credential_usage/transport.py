"""Usage Readers send HTTP requests through a transport bound to one credential."""

from collections.abc import Callable, Mapping
from concurrent.futures import Future
from dataclasses import dataclass
import math
from threading import Thread
import time
from typing import Annotated, Literal, Protocol, Self

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, SecretStr
import urllib3
from urllib3.util import Retry


class FrozenModel(BaseModel):
    """Parse wire values strictly and keep credential details out of diagnostics."""

    model_config = ConfigDict(frozen=True, strict=True, hide_input_in_errors=True)


class HttpRequest(FrozenModel):
    """The vendor supplies the payload and headers. The transport supplies authorization."""

    method: Literal["GET", "POST"]
    url: HttpUrl
    headers: dict[str, str] = {}
    body: str | None = None

    def bearer_headers(self, endpoint: HttpUrl, token: str) -> dict[str, str]:
        """Keep vendor headers while reserving authority and authorization for the binding."""
        if origin(self.url) != origin(endpoint):
            raise RequestFailure("credential origin mismatch")
        return {
            **{
                k: v
                for k, v in self.headers.items()
                if k.lower() not in {"authorization", "host"}
            },
            "Authorization": f"Bearer {token}",
        }


DEADLINE_VARIABLE = "CREDENTIAL_USAGE_READER_TIMEOUT"
# The runner kills the Reader at its deadline; the Reader still has to print its envelope.
DEADLINE_MARGIN = 0.5


def reader_deadline(environ: Mapping[str, str]) -> float | None:
    """Return the instant the runner's seconds run out, counted from now, or None when it sets none.

    The runner exports the seconds left in DEADLINE_VARIABLE. An unset or
    unreadable value leaves the policy timeout as the only bound.
    """
    try:
        left = math.inf if (seconds := environ.get(DEADLINE_VARIABLE)) is None else float(seconds)
    except ValueError:
        return None
    return time.monotonic() + left if math.isfinite(left) else None


class RequestFailure(Exception):
    """Readers can report the failure message and inspect an HTTP status without a body."""

    def __init__(self, reason: str, status: int | None = None):
        super().__init__(reason)
        self.status = status


class HttpResponse(FrozenModel):
    """Direct HTTP and CPA both return the successful upstream status and text body."""

    status_code: Annotated[int, Field(ge=100, le=599)]
    body: str

    def checked(self) -> Self:
        """Discard private response bodies when reporting an unsuccessful request."""
        if not 200 <= self.status_code < 300:
            raise RequestFailure(f"HTTP {self.status_code}", self.status_code)
        return self


class Transport(Protocol):
    """Readers receive a successful HTTP response or a safe RequestFailure."""

    def request(self, request: HttpRequest) -> HttpResponse: ...


def origin(url: HttpUrl) -> tuple[str, str | None, int | None]:
    """A credential stays on its configured scheme, host and port."""
    return url.scheme, url.host, url.port


class HttpPolicy(FrozenModel):
    """The HTTP client owns the timeout and network retries for each operation."""

    retries: int = Field(default=0, ge=0)
    timeout: float = Field(default=10, gt=0, allow_inf_nan=False)


def deliver(reply: Future[HttpResponse], send: Callable[[], HttpResponse]) -> None:
    """Hand the reply, or its failure, to the thread that is waiting for it."""
    try:
        reply.set_result(send())
    except BaseException as error:
        reply.set_exception(error)


@dataclass(frozen=True)
class DirectHttp:
    """Send the local bearer token only to this origin, including when CPA is the origin."""

    endpoint: HttpUrl
    token: SecretStr
    policy: HttpPolicy = HttpPolicy()
    deadline: float | None = None

    def request_timeout(self) -> float:
        """Return how long the next request may wait, or refuse it once the deadline is too close."""
        if self.deadline is None:
            return self.policy.timeout
        left = self.deadline - time.monotonic() - DEADLINE_MARGIN
        if left <= 0:
            raise RequestFailure("HTTP request deadline passed")
        return min(self.policy.timeout, left)

    def request(self, request: HttpRequest) -> HttpResponse:
        """Send the request and wait no longer than its timeout, retries included."""
        budget = self.request_timeout()
        if self.deadline is None:
            return self.send(request, budget)
        # A name lookup or a trickling reply ignores the socket timeout, so this thread keeps time.
        reply: Future[HttpResponse] = Future()
        Thread(target=deliver, args=(reply, lambda: self.send(request, budget)), daemon=True).start()
        try:
            return reply.result(timeout=budget)
        except TimeoutError:
            raise RequestFailure("HTTP request deadline passed") from None

    def send(self, request: HttpRequest, timeout: float) -> HttpResponse:
        """Apply the binding and let the HTTP library retry network failures without redirects."""
        try:
            response = urllib3.request(
                request.method,
                str(request.url),
                headers=request.bearer_headers(
                    self.endpoint, self.token.get_secret_value()
                ),
                body=request.body,
                timeout=timeout,
                redirect=False,
                retries=Retry(
                    total=self.policy.retries,
                    allowed_methods=None,
                    respect_retry_after_header=False,
                ),
            )
            return HttpResponse(
                status_code=response.status,
                body=response.data.decode() if 200 <= response.status < 300 else "",
            ).checked()
        except (urllib3.exceptions.HTTPError, OSError, ValueError):
            raise RequestFailure("HTTP request failed") from None
