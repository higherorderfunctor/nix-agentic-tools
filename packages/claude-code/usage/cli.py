"""The claude-usage command emits allowance windows, prepaid credits and reset grants for one login."""

from collections.abc import Callable, Mapping
from datetime import UTC, datetime
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Annotated, NamedTuple

from pydantic import Field, HttpUrl, SecretStr, ValidationError

from cliproxyapi.usage.transport import CpaInstance, UnknownBinding
from credential_usage.envelope import Account, Binding
from credential_usage.transport import DirectHttp, FrozenModel, RequestFailure, Transport

from .claude import VENDOR, read_usage


class Settings(FrozenModel):
    """Read just the environment variables that locate a Claude or CPA credential."""

    HOME: str | None = None
    CLAUDE_CONFIG_DIR: str | None = None
    DELEGATE_USAGE_CPA_CLAUDE_URL: str | None = None
    DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE: str | None = None


class OAuth(FrozenModel):
    """Extract the bearer token from Claude's local OAuth entry."""

    accessToken: Annotated[SecretStr, Field(min_length=1)]


class Credentials(FrozenModel):
    """Select the OAuth login in Claude's credentials file."""

    claudeAiOauth: OAuth


class BoundAccount(NamedTuple):
    """Carry the chosen transport together with its public attribution."""

    transport: Transport
    binding: Binding
    account: Account


def direct_account(settings: Settings) -> BoundAccount:
    """Bind the vendor origin to the token in the configured Claude directory."""
    try:
        if settings.CLAUDE_CONFIG_DIR:
            directory = Path(settings.CLAUDE_CONFIG_DIR)
        elif settings.HOME:
            directory = Path(settings.HOME) / ".claude"
        else:
            raise RequestFailure("claude credentials unavailable")
        login = Credentials.model_validate_json((directory / ".credentials.json").read_bytes())
    except (OSError, ValueError):
        raise RequestFailure("claude credentials unavailable") from None
    return BoundAccount(
        DirectHttp(VENDOR, login.claudeAiOauth.accessToken), Binding(transport="direct", endpoint=VENDOR),
        Account(auth_index=None, name=None, plan=None),
    )


def configured_cpa_account(settings: Settings) -> BoundAccount | None:
    """Discover exactly one eligible login when the environment selects a CPA instance."""
    url, key_file = settings.DELEGATE_USAGE_CPA_CLAUDE_URL, settings.DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE
    if not url and not key_file:
        return None
    if not url or not key_file:
        raise RequestFailure("incomplete claude proxy configuration")
    try:
        binding = Binding(endpoint=HttpUrl(url), transport="cpa")
        key = Path(key_file).read_bytes().decode().removesuffix("\n")
        if not key or "\n" in key or "\r" in key:
            raise ValueError
        management = DirectHttp(binding.endpoint, SecretStr(key))
        selected = CpaInstance(binding.endpoint, management).bind(VENDOR, provider="claude")
    except (OSError, ValueError, RequestFailure):
        raise RequestFailure("claude proxy binding unavailable") from None
    if isinstance(selected, UnknownBinding):
        raise RequestFailure("claude proxy requires one eligible login")
    return BoundAccount(
        selected, binding, Account(auth_index=selected.auth_index, name=selected.account_name or selected.auth_index, plan=None)
    )


def user_agent(env: Mapping[str, str]) -> str:
    """Accept only Claude's version line before sending a vendor request."""
    try:
        output = subprocess.check_output(["claude", "--version"], env=env, stderr=subprocess.DEVNULL, timeout=15)
        version = re.fullmatch(rb"([0-9]+\.[0-9]+\.[0-9]+(?:[+-][a-zA-Z0-9.-]+)?)(?: \(Claude Code\))?", output.rstrip(b"\n"))
        if version:
            return f"claude-cli/{version[1].decode('ascii')} (external, cli)"
    except (OSError, subprocess.SubprocessError):
        pass
    raise RequestFailure("claude version unavailable or invalid")


def main(env: Mapping[str, str], clock: Callable[[], datetime]) -> int:
    """Print one versioned observation or one public failure line for the routing helper."""
    try:
        settings = Settings.model_validate(env)
        bound = configured_cpa_account(settings)
        agent = user_agent(env)
        bound = bound or direct_account(settings)
        result = read_usage(*bound, agent, clock)
    except (RequestFailure, ValidationError) as error:
        reason = str(error) if isinstance(error, RequestFailure) else "invalid claude usage response"
        print(f"usage: {reason}", file=sys.stderr)
        return 1
    print(result.model_dump_json())
    return 0


if __name__ == "__main__":
    sys.exit(main(os.environ, lambda: datetime.now(UTC)))
