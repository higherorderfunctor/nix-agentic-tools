#!/usr/bin/env python3
# cspell:ignore sgra
"""Typed payloads shared by the scribe daemon and its clients."""

from typing import Literal

import pydantic


class GrammarField(pydantic.BaseModel):
    model_config = pydantic.ConfigDict(extra="forbid", strict=True)

    name: str
    kind: str
    required: bool
    options: list[str]


class GrammarRole(pydantic.BaseModel):
    model_config = pydantic.ConfigDict(extra="forbid", strict=True)

    role: str | None
    type: str
    reverse: str | None


class GrammarType(pydantic.BaseModel):
    model_config = pydantic.ConfigDict(extra="forbid", strict=True)

    prefix: str
    fields: list[GrammarField]
    roles: list[GrammarRole]


class WorkspaceGrammarResult(pydantic.BaseModel):
    """The complete author-facing grammar served by one workspace."""

    model_config = pydantic.ConfigDict(extra="forbid", populate_by_name=True, strict=True)

    types: dict[str, GrammarType]
    schema_: Literal["scribe-grammar/1"] = pydantic.Field(
        default="scribe-grammar/1",
        alias="schema",
    )
