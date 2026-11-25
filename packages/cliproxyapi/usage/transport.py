"""Bind a Reader to one CPA credential, then forward its vendor requests through api-call."""

from collections.abc import Iterable
from dataclasses import dataclass
from enum import Enum
import json
from pathlib import Path

from pydantic import Field, HttpUrl, SecretStr, TypeAdapter, ValidationError, field_validator

from credential_usage.transport import (
    DirectHttp,
    FrozenModel,
    HttpPolicy,
    HttpRequest,
    HttpResponse,
    RequestFailure,
    Transport,
    origin,
)


class CpaBinding(FrozenModel):
    """Connect to a registered management endpoint using its runtime key file."""

    endpoint: HttpUrl
    managementKeyFile: str
    pin: str | None = None
    policy: HttpPolicy = HttpPolicy()

    def instance(self) -> "CpaInstance":
        """Load the management key only when running the Reader."""
        key = Path(self.managementKeyFile).read_bytes().decode().removesuffix("\n")
        if not key or "\n" in key or "\r" in key:
            raise RequestFailure("invalid management key file")
        return CpaInstance(self.endpoint, DirectHttp(self.endpoint, SecretStr(key), self.policy))


class AuthFile(FrozenModel):
    """CPA lists logins alongside disabled accounts and other credential types."""

    account_type: str | None = None
    auth_index: str | None = None
    disabled: bool = False
    email: str | None = None
    name: str | None = None
    provider: str | None = None

    @field_validator("email", "name", mode="before")
    @classmethod
    def optional_label(cls, value: object) -> str | None:
        """Keep optional attribution independent of credential selection."""
        return value if isinstance(value, str) else None


class AuthFiles(FrozenModel):
    """The auth-files response wraps all accounts in a files array."""

    files: tuple[AuthFile, ...]


class ConfiguredKey(FrozenModel):
    """CPA exposes the secret for deduplication and an index for forwarding."""

    api_key: SecretStr | None = Field(default=None, alias="api-key")
    auth_index: str | None = None


class KeyGroup(FrozenModel):
    """A config/api-keys collection groups keys under their upstream base URL."""

    base_url: HttpUrl | None = Field(default=None, alias="base-url")
    keys: tuple[ConfiguredKey, ...] = ()


key_groups = TypeAdapter(tuple[KeyGroup, ...])


class UnknownBinding(Enum):
    """A Reader with no unique eligible credential cannot attribute a capture."""

    ABSENT = "no matching credential"
    AMBIGUOUS = "ambiguous credentials"


@dataclass(frozen=True)
class CpaInstance:
    """Use this instance's management transport to discover and pin a vendor credential."""

    url: HttpUrl
    management: Transport

    def call(self, path: str, payload: str | None = None) -> HttpResponse:
        """Send the management endpoint its JSON payload through the instance binding."""
        return self.management.request(
            HttpRequest(
                method="GET" if payload is None else "POST",
                url=HttpUrl(f"{str(self.url).rstrip('/')}/{path}"),
                headers={"Content-Type": "application/json"},
                body=payload,
            )
        )

    def bind(
        self,
        discovery_base: HttpUrl,
        *,
        provider: str | None = None,
        surfaces: tuple[str, ...] | None = None,
        pin: str | None = None,
    ) -> "CpaTransport | UnknownBinding":
        """Use a registered pin directly, or verify a selection against the specified discovery source."""
        if provider is not None and surfaces is not None:
            raise RequestFailure("conflicting CPA discovery sources")
        if provider is None and surfaces is None:
            return CpaTransport(self, discovery_base, pin) if pin else UnknownBinding.ABSENT
        candidates: list[tuple[str | SecretStr, str, str | None]] = []
        try:
            if provider is not None:
                accounts = AuthFiles.model_validate_json(
                    self.call("v0/management/auth-files").body
                )
                candidates.extend(
                    (login.auth_index, login.auth_index, login.email or login.name)
                    for login in accounts.files
                    if login.provider == provider
                    and login.account_type == "oauth"
                    and not login.disabled
                    and login.auth_index
                )
            elif surfaces is not None:
                for key in self.endpoint_keys(discovery_base, surfaces):
                    if key.auth_index and key.api_key:
                        candidates.append((key.api_key, key.auth_index, None))
        except ValidationError:
            raise RequestFailure("invalid CPA discovery response") from None
        distinct: dict[str | SecretStr, tuple[str, str | None]] = {}
        for identity, index, name in candidates:
            if pin is None or index == pin:
                distinct.setdefault(identity, (index, name))
        if not distinct:
            return UnknownBinding.ABSENT
        if len(distinct) > 1:
            return UnknownBinding.AMBIGUOUS
        return CpaTransport(self, discovery_base, *next(iter(distinct.values())))

    def endpoint_keys(
        self, discovery_base: HttpUrl, surfaces: tuple[str, ...]
    ) -> Iterable[ConfiguredKey]:
        """Yield keys at the discovery base path or below it on the same origin."""
        prefix = (discovery_base.path or "").rstrip("/") + "/"
        for surface in surfaces:
            try:
                response = self.call(f"v8/management/config/api-keys/{surface}")
            except RequestFailure as error:
                if error.status == 404:
                    continue
                raise
            for group in key_groups.validate_json(response.body, strict=True):
                base = group.base_url
                if (
                    base
                    and origin(base) == origin(discovery_base)
                    and ((base.path or "").rstrip("/") + "/").startswith(prefix)
                ):
                    yield from group.keys


@dataclass(frozen=True)
class CpaTransport:
    """Send only the selected index and token placeholder to CPA for the bound vendor."""

    instance: CpaInstance
    discovery_base: HttpUrl
    auth_index: str
    account_name: str | None = None

    def request(self, request: HttpRequest) -> HttpResponse:
        """Forward quota requests anywhere on the discovery origin and check both HTTP statuses."""
        payload = {
            "method": request.method,
            "url": str(request.url),
            "auth_index": self.auth_index,
            "header": request.bearer_headers(self.discovery_base, "$TOKEN$"),
        }
        if request.body is not None:
            payload["data"] = request.body
        outer = self.instance.call("v0/management/api-call", json.dumps(payload))
        try:
            return HttpResponse.model_validate_json(outer.body).checked()
        except ValidationError:
            raise RequestFailure("invalid CPA api-call response") from None
