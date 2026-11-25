# pyright: strict
# cspell:ignore lineterm
"""Fill owners replay their paired fixtures here to compare the entire Reader command boundary.

Both files of a pair list the same scenarios. An entry writes once what both transports share (the
fields beside `extends`) and writes under `direct` or `cpa` what one transport alone changes. One
merge rule joins the two, then joins them onto the full case the entry `extends`: objects merge by
key; arrays and scalars replace. A full case (`"extends": null`) has nothing beneath it, so what it
writes must be complete on every declared transport.
"""

from collections.abc import Callable, Generator, Iterator, Mapping, Sequence
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta
from difflib import unified_diff
from functools import cached_property
from importlib import import_module
import json
import os
from pathlib import Path
import re
from shutil import which
import sys
from tempfile import TemporaryDirectory, TemporaryFile
from typing import Annotated, Literal, NamedTuple, TextIO, cast, get_args

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, JsonValue, TypeAdapter, ValidationError, field_validator
from urllib3.response import HTTPResponse
from unittest.mock import patch

from credential_usage.envelope import Envelope


Entry = Callable[[Mapping[str, str], Callable[[], datetime]], int]
TransportName = Literal["cpa", "direct"]
TRANSPORTS = frozenset(get_args(TransportName))
FileName = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-][A-Za-z0-9_.-]*$")]
Document = dict[str, JsonValue]


def credential_path(path: str) -> str:
    """Keep every credential beneath the fixture directory, including nested dotfiles."""
    if any(part in (".", "..") for part in path.split("/")):
        raise ValueError("expected a relative credential path without directory aliases")
    return path


CredentialPath = Annotated[str, Field(pattern=r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$"), AfterValidator(credential_path)]


CredentialFiles = dict[CredentialPath, Annotated[str, Field(min_length=1)]]


class FixtureModel(BaseModel):
    """Reject misspelled fixture fields before running a Reader."""
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class WrappedBody(FixtureModel):
    """Write a CPA wrapper whose inner body already has a literal fixture."""

    status_code: Annotated[int, Field(ge=100, le=599)]
    body_from: str


class ReplyFixture(FixtureModel):
    """Declare the HTTP status and body, including explicit private replies."""

    status: Annotated[int, Field(ge=100, le=599)]
    body: str | WrappedBody
    private: bool = False


class Reply(NamedTuple):
    """Deliver the resolved status and exact HTTP response text."""

    status: int
    body: str
    private: bool


def merged(base: Document, override: Document) -> Document:
    """Apply the pair's merge rule to two JSON objects."""
    whole = base.copy()
    for key, value in override.items():
        before = whole.get(key)
        whole[key] = merged(before, value) if isinstance(before, dict) and isinstance(value, dict) else value
    return whole


class Scenario(FixtureModel):
    """Set the binding environment and select replies in request order."""

    env: dict[str, str]
    replies: list[str]
    credentials: CredentialFiles = Field(default_factory=dict)


class CaseEntry(FixtureModel):
    """One scenario's or expectation's entry: what both transports change and what one transport changes alone."""

    # The fields beside `extends` are the shared changes, so the model keeps them instead of refusing them.

    model_config = ConfigDict(extra="allow", strict=True, hide_input_in_errors=True)

    extends: FileName | None
    cpa: Document = Field(default_factory=dict)
    direct: Document = Field(default_factory=dict)

    def transport_overrides(self, transport: TransportName) -> Document:
        """Return what the entry changes on one transport: the shared fields, then that transport's own."""
        return merged(cast(Document, self.model_extra), self.cpa if transport == "cpa" else self.direct)


def expanded_cases(entries: Mapping[str, CaseEntry], transports: Sequence[TransportName]) -> dict[str, dict[TransportName, Document]]:
    """Return each entry's complete object on every transport, built from the full case it extends."""
    objects: dict[str, dict[TransportName, Document]] = {}
    for name, entry in entries.items():
        if entry.extends is None:
            objects[name] = {transport: entry.transport_overrides(transport) for transport in transports}
    for name, entry in entries.items():
        if entry.extends is not None:
            objects[name] = {transport: merged(objects[entry.extends][transport], entry.transport_overrides(transport)) for transport in transports}
    return objects


class Inputs(FixtureModel):
    """Read the shared supplies and each scenario from input.json."""

    description: str
    transports: Annotated[list[TransportName], Field(min_length=1)]
    now: datetime
    reply_fixtures: dict[str, ReplyFixture] = Field(alias="replies")
    credentials: CredentialFiles
    executables: dict[FileName, str]
    scenarios: Annotated[dict[FileName, CaseEntry], Field(min_length=1)]

    @cached_property
    def replies(self) -> dict[str, Reply]:
        """Resolve wrapper references against literal bodies before replay."""
        replies: dict[str, Reply] = {}
        for name, fixture in self.reply_fixtures.items():
            body = fixture.body
            if isinstance(body, WrappedBody):
                source = self.reply_fixtures.get(body.body_from)
                if source is None or not isinstance(source.body, str):
                    raise IncompletePair(f"{name}: wrapper requires a literal reply body")
                body = json.dumps({"status_code": body.status_code, "body": source.body},
                                  ensure_ascii=False, separators=(",", ":"))
            replies[name] = Reply(fixture.status, body, fixture.private)
        return replies

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


def described(error: ValidationError) -> str:
    """Name each invalid field of a built case without repeating its value."""
    return "; ".join(f"{'.'.join(map(str, part['loc']))}: {part['msg']}" for part in error.errors())


class Pair(NamedTuple):
    """Load both files and require a complete grid before selecting any case."""

    inputs: Inputs
    cases: dict[str, Case]

    @classmethod
    def read(cls, directory: Path) -> "Pair":
        """Match every scenario on every declared transport to exactly one expectation."""
        inputs = Inputs.model_validate_json((directory / "input.json").read_bytes())
        replies = inputs.replies
        expectations = TypeAdapter(dict[FileName, CaseEntry]).validate_json(
            (directory / "expected.json").read_bytes(), strict=True
        )
        declared = set(inputs.transports)
        if inputs.scenarios.keys() != expectations.keys() or len(declared) != len(inputs.transports):
            raise IncompletePair("pair: scenario or transport declarations differ")
        for name, scenario_entry in inputs.scenarios.items():
            expected_entry = expectations[name]
            parent = scenario_entry.extends
            if parent != expected_entry.extends:
                raise IncompletePair(f"{name}: extends differs between input.json and expected.json")
            if parent is not None and (parent not in inputs.scenarios or inputs.scenarios[parent].extends is not None):
                raise IncompletePair(f"{name}: extends {parent}, which is not a full case")
            for piece in (scenario_entry, expected_entry):
                if (piece.model_fields_set & TRANSPORTS) - declared:
                    raise IncompletePair(f"{name}: transport coverage differs")
        scenario_objects = expanded_cases(inputs.scenarios, inputs.transports)
        expected_objects = expanded_cases(expectations, inputs.transports)
        cases: dict[str, Case] = {}
        for name in inputs.scenarios:
            for transport in inputs.transports:
                key = f"{name}/{transport}"
                try:
                    scenario = Scenario.model_validate(scenario_objects[name][transport])
                    expectation = Expected.model_validate(expected_objects[name][transport])
                except ValidationError as error:
                    raise IncompletePair(f"{key}: {described(error)}") from None
                if any(reply not in replies for reply in scenario.replies):
                    raise IncompletePair(f"{key}: unknown reply")
                cases[key] = Case(key, scenario, expectation)
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


def hidden_text(credentials: CredentialFiles, replies: Sequence[Reply]) -> tuple[dict[str, str], list[str]]:
    """Map each credential spelling to its placeholder and list each spelling a failed reply keeps out of output."""
    masks = {
        spelling: f"[credential:{name}]"
        for name, content in credentials.items()
        for value in private_strings(content)
        for spelling in (value, json.dumps(value)[1:-1])
    }
    private = [
        spelling
        for reply in replies if reply.private or not 200 <= reply.status < 300
        for value in private_strings(reply.body)
        for spelling in (value, json.dumps(value)[1:-1])
    ]
    return masks, private


def conceal(values: Mapping[str, str]) -> Callable[[str], str]:
    """Return a function that swaps each key for its value, longest first, so no diagnostic repeats a private string."""
    if not values:
        return lambda text: text
    pattern = re.compile("|".join(map(re.escape, sorted(values, key=len, reverse=True))))

    def swap(text: str) -> str:
        return pattern.sub(lambda match: values[match[0]], text)

    return swap


def recorded_request(
    mask: Callable[[str], str], method: str, url: str, headers: Mapping[str, str], body: str | None,
) -> Request:
    """Mask the trace and compare a JSON request body as data when it is present."""
    payload: JsonValue = None
    if body is not None:
        payload = mask(body)
        try:
            payload = TypeAdapter(JsonValue).validate_json(payload)
        except ValidationError:
            pass
    return Request(method=mask(method), url=mask(url), body=payload,
                   headers={mask(key): mask(value) for key, value in headers.items()})


class ScriptedNetwork:
    """Serve one reply per HTTP call and stamp observations with the completed call count."""

    def __init__(self, start: datetime, replies: list[Reply], masks: Mapping[str, str]):
        self.start = start
        self.replies = replies
        self.mask = conceal(masks)
        self.requests: list[Request] = []

    def clock(self) -> datetime:
        return self.start + timedelta(seconds=len(self.requests))

    def request(
        self, method: str, url: str, *, headers: dict[str, str] | None = None,
        body: str | None = None, **_: object,
    ) -> HTTPResponse:
        """Record before replying so even a Reader that catches an extra request fails its case."""
        self.requests.append(recorded_request(self.mask, method, url, headers or {}, body))
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
        path.parent.mkdir(parents=True, exist_ok=True)
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
            document: object = json.loads(out)
            Envelope.model_validate(document)
            return cast(Document, document)
        except (ValueError, RecursionError):
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


class Difference(NamedTuple):
    """A failed comparison: its case and kind, then the whole objects that differed when two were compared."""

    label: str
    diff: str = ""

    def __str__(self) -> str:
        return f"{self.label}\n{self.diff}" if self.diff else self.label


def whole_numbers(value: JsonValue) -> JsonValue:
    """Write a whole float as an integer so a diff shows only what the comparison counts as different."""
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, dict):
        return {key: whole_numbers(part) for key, part in value.items()}
    if isinstance(value, list):
        return [whole_numbers(part) for part in value]
    return value


def diff_of(expected: JsonValue, observed: JsonValue, mask: Callable[[str], str]) -> str:
    """Diff the complete expected and observed objects with every private string replaced."""
    before = mask(json.dumps(whole_numbers(expected), indent=2, sort_keys=True)).splitlines()
    after = mask(json.dumps(whole_numbers(observed), indent=2, sort_keys=True)).splitlines()
    return "\n".join(unified_diff(before, after, "expected", "observed", n=len(before), lineterm=""))


class Replay(NamedTuple):
    """Prepare the same fixture credentials and response script for either capture path."""

    credentials: CredentialFiles
    replies: list[Reply]
    masks: dict[str, str]
    private: list[str]

    @classmethod
    def for_case(cls, inputs: Inputs, case: Case) -> "Replay":
        credentials = inputs.credentials | case.scenario.credentials
        replies = [inputs.replies[name] for name in case.scenario.replies]
        masks, private = hidden_text(credentials, replies)
        return cls(credentials, replies, masks, private)

    def compare(
        self, case: Case, out: str, err: str, requests: Sequence[Request],
        expected_result: Document, observed: Document | None,
    ) -> list[Difference]:
        """Compare raw streams and count, then the entire public trace and result."""
        errors: list[Difference] = []
        redact = conceal(self.masks | dict.fromkeys(self.private, "[private]"))
        if any(secret in stream for stream in (out, err) for secret in [*self.masks, *self.private]):
            errors.append(Difference(f"{case.name}: leak"))
        if len(requests) != len(self.replies):
            kind = "extra request" if len(requests) > len(self.replies) else "missing request"
            errors.append(Difference(f"{case.name}: {kind}"))
        expected_trace: JsonValue = [request.model_dump() for request in case.expected.requests]
        trace: JsonValue = [request.model_dump() for request in requests]
        if not same_json(trace, expected_trace):
            errors.append(Difference(f"{case.name}: trace", diff_of(expected_trace, trace, redact)))
        if not same_json(observed, expected_result):
            errors.append(Difference(f"{case.name}: result", diff_of(expected_result, observed, redact)))
        return errors


def differences(inputs: Inputs, case: Case, entry: str) -> list[Difference]:
    """Run the actual command and return one safe report for every failed comparison."""
    errors: list[Difference] = []
    replay = Replay.for_case(inputs, case)
    network = ScriptedNetwork(inputs.now, replay.replies, replay.masks)
    with TemporaryDirectory() as tmp:
        env = case_environment(Path(tmp), inputs.executables, case.scenario.env, replay.credentials)
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
                        errors.append(Difference(f"{case.name}: import output"))
                status = command(env, network.clock)
            except KeyboardInterrupt:
                raise
            except BaseException:
                # Exception text can include a raw body or a credential.
                status = None

            stdout.seek(0)
            stderr.seek(0)
            out, err = stdout.read(), stderr.read()

    return errors + replay.compare(case, out, err, network.requests, case.expected.result, public_result(status, out, err))
