"""Embedding-model routes from the same runtime configuration as the CLI."""

from semble.nix_config import CONFIG

DEFAULT_CONTENT: list[str] = CONFIG["defaultContent"]
DEFAULT_MODEL: str | None = CONFIG["defaultModel"]
MODELS: list[dict] = CONFIG["models"]
