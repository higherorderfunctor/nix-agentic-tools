"""Usage Readers send HTTP requests through a transport bound to one credential."""

from dataclasses import dataclass
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
    timeout: float = Field(default=75, gt=0, allow_inf_nan=False)


@dataclass(frozen=True)
class DirectHttp:
    """Send the local bearer token only to this origin, including when CPA is the origin."""

    endpoint: HttpUrl
    token: SecretStr
    policy: HttpPolicy = HttpPolicy()

    def request(self, request: HttpRequest) -> HttpResponse:
        """Apply the binding and let the HTTP library retry network failures without redirects."""
        try:
            response = urllib3.request(
                request.method,
                str(request.url),
                headers=request.bearer_headers(
                    self.endpoint, self.token.get_secret_value()
                ),
                body=request.body,
                timeout=self.policy.timeout,
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
