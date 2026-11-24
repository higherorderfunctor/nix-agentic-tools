# pyright: strict
"""Fill owners replay their paired fixtures here to compare the entire Reader command boundary."""

from collections.abc import Callable, Generator, Iterator, Mapping
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta
from importlib import import_module
import json
import os
from pathlib import Path
import re
from shutil import which
import sys
from tempfile import TemporaryDirectory, TemporaryFile
from typing import Annotated, Literal, NamedTuple, TextIO, cast

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, JsonValue, TypeAdapter, ValidationError, field_validator
from urllib3.response import HTTPResponse
from unittest.mock import patch

from credential_usage.envelope import Envelope


Entry = Callable[[Mapping[str, str], Callable[[], datetime]], int]
TransportName = Literal["cpa", "direct"]
FileName = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-][A-Za-z0-9_.-]*$")]
Document = dict[str, JsonValue]


def credential_file_name(name: str) -> str:
    """Keep dotfiles in the fixture directory and refuse the two directory aliases."""
    if name in (".", ".."):
        raise ValueError("expected a credential file name")
    return name


CredentialFileName = Annotated[str, Field(pattern=r"^[A-Za-z0-9_.-]+$"), AfterValidator(credential_file_name)]


CredentialFiles = dict[CredentialFileName, Annotated[str, Field(min_length=1)]]


class FixtureModel(BaseModel):
    """Reject misspelled fixture fields before running a Reader."""
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class Reply(FixtureModel):
    """Deliver the scripted status and literal HTTP response text."""
    status: Annotated[int, Field(ge=100, le=599)]
    body: str
    private: bool = False


class Scenario(FixtureModel):
    """Set the binding environment and select replies in request order."""
    env: dict[str, str]
    replies: list[str]
    credentials: CredentialFiles = Field(default_factory=dict)


class Inputs(FixtureModel):
    """Read the shared supplies and each transport's scenario from input.json."""
    description: str
    transports: Annotated[list[TransportName], Field(min_length=1)]
    now: datetime
    replies: dict[str, Reply]
    credentials: CredentialFiles
    executables: dict[FileName, str]
    scenarios: Annotated[dict[FileName, dict[TransportName, Scenario]], Field(min_length=1)]

    @field_validator("now", mode="before")
    @classmethod
    def utc_start(cls, value: object) -> datetime:
        """Require a UTC fixture instant so every machine starts at the same time."""
        if not isinstance(value, str) or not value.endswith("Z"):
            raise ValueError("now must be a timestamp ending in Z")
        return datetime.fromisoformat(value)


class Request(FixtureModel):
    """Compare the complete wire request, including a structural JSON body when present."""
    method: str
    url: str
    headers: dict[str, str]
    body: JsonValue


class Expected(FixtureModel):
    """Keep the author's literal result independent of the Reader's model and conversions."""
    requests: list[Request]
    result: Document


class Case(NamedTuple):
    """A runner can select one scenario and transport without skipping pair validation."""
    name: str
    scenario: Scenario
    expected: Expected


class IncompletePair(ValueError):
    """Carry only public case identifiers to the runner when a fixture cannot be replayed."""


class Pair(NamedTuple):
    """Load both files and require a complete grid before selecting any case."""
    inputs: Inputs
    cases: dict[str, Case]

    @classmethod
    def read(cls, directory: Path) -> "Pair":
        """Match every scenario on every declared transport to exactly one expectation."""
        inputs = Inputs.model_validate_json((directory / "input.json").read_bytes())
        expected = TypeAdapter(dict[str, dict[TransportName, Expected]]).validate_json(
            (directory / "expected.json").read_bytes(), strict=True
        )
        if inputs.scenarios.keys() != expected.keys() or len(set(inputs.transports)) != len(inputs.transports):
            raise IncompletePair("pair: scenario or transport declarations differ")
        cases: dict[str, Case] = {}
        for name, scenarios in inputs.scenarios.items():
            if set(inputs.transports) != scenarios.keys() or scenarios.keys() != expected[name].keys():
                raise IncompletePair(f"{name}: transport coverage differs")
            for transport, scenario in scenarios.items():
                key = f"{name}/{transport}"
                if any(reply not in inputs.replies for reply in scenario.replies):
                    raise IncompletePair(f"{key}: unknown reply")
                cases[key] = Case(key, scenario, expected[name][transport])
        return cls(inputs, cases)


def private_strings(content: str) -> Iterator[str]:
    """Find literal private text and strings a Reader can extract from nested JSON."""
    if not content:
        return
    yield content
    if content.strip() and content.strip() != content:
        yield content.strip()
    try:
        parsed = TypeAdapter(JsonValue).validate_json(content)
    except ValidationError:
        return

    def strings(value: JsonValue) -> Iterator[str]:
        if isinstance(value, str) and value:
            yield from private_strings(value)
        elif isinstance(value, dict):
            for part in value.values():
                yield from strings(part)
        elif isinstance(value, list):
            for part in value:
                yield from strings(part)

    yield from strings(parsed)


class ScriptedNetwork:
    """Serve one reply per HTTP call and stamp observations with the completed call count."""

    def __init__(self, start: datetime, replies: list[Reply], masks: dict[str, str]):
        self.start = start
        self.replies = replies
        self.masks = masks
        alternatives = sorted(masks, key=len, reverse=True)
        self.pattern = re.compile("|".join(map(re.escape, alternatives))) if alternatives else None
        self.requests: list[Request] = []

    def clock(self) -> datetime:
        return self.start + timedelta(seconds=len(self.requests))

    def mask(self, value: str) -> str:
        if self.pattern is None:
            return value
        return self.pattern.sub(lambda match: self.masks[match[0]], value)

    def request(
        self, method: str, url: str, *, headers: dict[str, str] | None = None,
        body: str | None = None, **_: object,
    ) -> HTTPResponse:
        """Record before replying so even a Reader that catches an extra request fails its case."""
        payload: JsonValue = None
        if body is not None:
            try:
                payload = TypeAdapter(JsonValue).validate_json(self.mask(body))
            except ValidationError:
                payload = self.mask(body)
        self.requests.append(Request(
            method=self.mask(method), url=self.mask(url),
            headers={self.mask(k): self.mask(v) for k, v in (headers or {}).items()}, body=payload,
        ))
        if len(self.requests) > len(self.replies):
            raise AssertionError("extra request")
        reply = self.replies[len(self.requests) - 1]
        return HTTPResponse(status=reply.status, body=reply.body.encode())


def case_environment(
    root: Path, executables: dict[str, str], settings: dict[str, str], credentials: CredentialFiles,
) -> dict[str, str]:
    """Give the command private credential files, an empty home and first choice of executables."""
    directory = root / "credentials"
    directory.mkdir()
    for name, content in credentials.items():
        path = directory / name
        path.write_text(content)
        path.chmod(0o600)
    programs = root / "bin"
    programs.mkdir()
    for name, script in executables.items():
        path = programs / name
        path.write_text(
            f"#!{which('bash') or '/bin/bash'}\n"
            "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
            f"{script}\n"
        )
        path.chmod(0o700)

    def expand(match: re.Match[str]) -> str:
        name = match[1]
        if name not in credentials:
            raise ValueError("unknown credential file")
        return str(directory / name)

    env = {"HOME": str(root), **{
        key: re.sub(r"\$\{credentials:([^}]+)\}", expand, value.replace("${bin}", str(programs)).replace("${credentialsDir}", str(directory)))
        for key, value in settings.items()
    }}
    env["PATH"] = os.pathsep.join((str(programs), env.get("PATH", os.environ.get("PATH", os.defpath))))
    return env


@contextmanager
def captured_stream(fd: Literal[1, 2]) -> Generator[TextIO]:
    """Capture Python writes and child processes that inherit the command's output descriptor."""
    redirect = redirect_stdout if fd == 1 else redirect_stderr
    with TemporaryFile("w+", encoding="utf-8", errors="replace", buffering=1) as output:
        saved = os.dup(fd)
        try:
            os.dup2(output.fileno(), fd)
            with redirect(output):
                yield output
        finally:
            os.dup2(saved, fd)
            os.close(saved)


def public_result(status: int | None, out: str, err: str) -> Document | None:
    """Decode one successful envelope or an exact public failure line as the command's consumer."""
    if status == 0:
        try:
            document = TypeAdapter(Document).validate_json(out, strict=True)
            Envelope.model_validate(document)
            return document
        except ValidationError:
            return None
    if status is not None and not out and re.fullmatch(r"usage: [^\r\n]+\n", err):
        return {"failed": err[:-1]}
    return None


def same_json(left: JsonValue, right: JsonValue) -> bool:
    """Compare JSON objects without treating true as 1 or false as 0 in Python."""
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(same_json(v, right[k]) for k, v in left.items())
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(same_json(a, b) for a, b in zip(left, right))
    return isinstance(left, bool) == isinstance(right, bool) and left == right


def differences(inputs: Inputs, case: Case, entry: str) -> list[str]:
    """Run the actual command and return only safe case labels for every failed comparison."""
    errors: list[str] = []
    replies = [inputs.replies[name] for name in case.scenario.replies]
    credentials = inputs.credentials | case.scenario.credentials
    masks = {
        spelling: f"[credential:{name}]"
        for name, content in credentials.items()
        for value in private_strings(content)
        for spelling in (value, json.dumps(value)[1:-1])
    }
    network = ScriptedNetwork(inputs.now, replies, masks)
    with TemporaryDirectory() as tmp:
        env = case_environment(Path(tmp), inputs.executables, case.scenario.env, credentials)
        with (
            patch.dict(sys.modules),
            patch.dict(os.environ, env, clear=True),
            patch("urllib3.request", network.request),
            captured_stream(1) as stdout,
            captured_stream(2) as stderr,
        ):
            try:
                module, name = entry.split(":")
                try:
                    command = cast(Entry, getattr(import_module(module), name))
                finally:
                    if stdout.tell() or stderr.tell():
                        errors.append("import output")
                status = command(env, network.clock)
            except KeyboardInterrupt:
                raise
            except BaseException:
                # Exception text can include a raw body or a credential.
                status = None

            stdout.seek(0)
            stderr.seek(0)
            out, err = stdout.read(), stderr.read()

    private = [*masks, *(value for reply in replies if reply.private or not 200 <= reply.status < 300
                         for value in private_strings(reply.body))]
    if any(secret in stream or json.dumps(secret)[1:-1] in stream for stream in (out, err) for secret in private):
        errors.append("leak")
    if len(network.requests) != len(replies):
        errors.append("extra request" if len(network.requests) > len(replies) else "missing request")
    if not same_json(
        [request.model_dump() for request in network.requests],
        [request.model_dump() for request in case.expected.requests],
    ):
        errors.append("trace")
    if not same_json(public_result(status, out, err), case.expected.result):
        errors.append("result")
    return [f"{case.name}: {error}" for error in errors]
