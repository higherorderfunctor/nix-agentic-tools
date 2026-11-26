# pyright: strict
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
import unittest
from unittest.mock import patch

from pydantic import AfterValidator, AwareDatetime, BaseModel, ConfigDict, Field, JsonValue, TypeAdapter, ValidationError
from urllib3.response import HTTPResponse

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


CredentialFiles = dict[
    Annotated[str, Field(pattern=r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$"), AfterValidator(credential_path)],
    Annotated[str, Field(min_length=1)],
]


class FixtureModel(BaseModel):
    """Reject misspelled fixture fields before running a Reader."""

    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class WrappedBody(FixtureModel):
    """Write a CPA wrapper whose inner body already has a literal fixture."""

    status_code: Annotated[int, Field(ge=100, le=599)]
    body_from: str


class ReplyFixture(FixtureModel):
    """Declare the HTTP status and body of one named reply: literal text, or a wrapper naming a literal."""

    status: Annotated[int, Field(ge=100, le=599)]
    body: str | WrappedBody


class Reply(NamedTuple):
    """Deliver the resolved status and exact HTTP response text."""

    status: int
    body: str


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
    replies: list[FileName]
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

    transports: Annotated[list[TransportName], Field(min_length=1)]
    now: AwareDatetime
    reply_fixtures: dict[str, ReplyFixture] = Field(alias="replies")
    credentials: CredentialFiles
    executables: dict[FileName, str] = Field(default_factory=dict)
    scenarios: Annotated[dict[FileName, CaseEntry], Field(min_length=1)]

    @cached_property
    def replies(self) -> dict[str, Reply]:
        """Resolve each CPA wrapper against the literal reply it names before replay."""
        replies: dict[str, Reply] = {}
        for name, fixture in self.reply_fixtures.items():
            body = fixture.body
            if isinstance(body, WrappedBody):
                source = self.reply_fixtures.get(body.body_from)
                if source is None or not isinstance(source.body, str):
                    raise ValueError(f"{name}: wrapper requires a literal reply body")
                body = json.dumps({"status_code": body.status_code, "body": source.body}, ensure_ascii=False, separators=(",", ":"))
            replies[name] = Reply(fixture.status, body)
        return replies


class Expected(FixtureModel):
    """Keep the author's literal request trace and result independent of the Reader's model and conversions."""

    requests: list[Document]
    result: Document


class Case(NamedTuple):
    """A runner can select one scenario and transport without skipping pair validation."""

    name: str
    scenario: Scenario
    expected: Expected


class Pair(NamedTuple):
    """Load both files and require a complete grid before selecting any case."""

    inputs: Inputs
    cases: dict[str, Case]

    @classmethod
    def read(cls, directory: Path) -> "Pair":
        """Match every scenario on every declared transport to exactly one expectation."""
        inputs = Inputs.model_validate_json((directory / "input.json").read_bytes())
        expectations = TypeAdapter(dict[FileName, CaseEntry]).validate_json(
            (directory / "expected.json").read_bytes(), strict=True
        )
        if inputs.scenarios.keys() != expectations.keys():
            raise ValueError("pair: scenario declarations differ")
        for name, scenario in inputs.scenarios.items():
            expected = expectations[name]
            parent = inputs.scenarios.get(scenario.extends or "")
            if scenario.extends != expected.extends:
                raise ValueError(f"{name}: extends differs between input.json and expected.json")
            if scenario.extends is not None and (parent is None or parent.extends is not None):
                raise ValueError(f"{name}: extends {scenario.extends}, which is not a full case")
            if any((piece.model_fields_set & TRANSPORTS) - set(inputs.transports) for piece in (scenario, expected)):
                raise ValueError(f"{name}: transport coverage differs")
        scenarios, expected = expanded_cases(inputs.scenarios, inputs.transports), expanded_cases(expectations, inputs.transports)
        cases: dict[str, Case] = {}
        for name in inputs.scenarios:
            for transport in inputs.transports:
                key = f"{name}/{transport}"
                try:
                    built = Scenario.model_validate(scenarios[name][transport])
                    expectation = Expected.model_validate(expected[name][transport])
                except ValidationError as error:
                    raise ValueError(f"{key}: {error}") from None
                if any(reply not in inputs.replies for reply in built.replies):
                    raise ValueError(f"{key}: unknown reply")
                cases[key] = Case(key, built, expectation)
        return cls(inputs, cases)


def credential_strings(content: str) -> Sequence[str]:
    """List a credential file's text and every string inside it, so output cannot carry a fragment."""
    try:
        parsed = TypeAdapter(JsonValue).validate_json(content)
    except ValidationError:
        return [content.strip()]

    def strings(value: JsonValue) -> Iterator[str]:
        if isinstance(value, str):
            yield value
        elif isinstance(value, dict):
            for part in value.values():
                yield from strings(part)
        elif isinstance(value, list):
            for part in value:
                yield from strings(part)

    return list(strings(parsed))


class ScriptedNetwork:
    """Serve one reply per HTTP call and stamp observations with the completed call count."""

    def __init__(self, start: datetime, replies: Sequence[Reply]) -> None:
        self.start = start
        self.replies = replies
        self.requests: list[Document] = []

    def clock(self) -> datetime:
        return self.start + timedelta(seconds=len(self.requests))

    def request(
        self, method: str, url: str, *, headers: dict[str, str] | None = None,
        body: str | None = None, **_: object,
    ) -> HTTPResponse:
        """Record the whole request before replying, so a Reader that catches an extra request still fails."""
        payload: JsonValue = body
        try:
            payload = TypeAdapter(JsonValue).validate_json(body) if body is not None else None
        except ValidationError:
            pass
        self.requests.append({"method": method, "url": url, "headers": dict(headers or {}), "body": payload})
        if len(self.requests) > len(self.replies):
            raise AssertionError("extra request")
        reply = self.replies[len(self.requests) - 1]
        return HTTPResponse(status=reply.status, body=reply.body.encode())


def case_environment(root: Path, inputs: Inputs, scenario: Scenario) -> dict[str, str]:
    """Give the command private credential files, an empty home and first choice of executables."""
    private, programs = root / "credentials", root / "bin"
    private.mkdir()
    programs.mkdir()
    credentials = inputs.credentials | scenario.credentials
    for name, content in credentials.items():
        path = private / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o600)
    for name, script in inputs.executables.items():
        path = programs / name
        path.write_text(
            f"#!{which('bash') or '/bin/bash'}\n"
            "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
            f"{script}\n"
        )
        path.chmod(0o700)

    def expand(match: re.Match[str]) -> str:
        return str(private / match[1])

    env = {"HOME": str(root)} | {
        key: re.sub(r"\$\{credentials:([^}]+)\}", expand, value.replace("${credentialsDir}", str(private)).replace("${bin}", str(programs)))
        for key, value in scenario.env.items()
    }
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


def compare(
    test: unittest.TestCase, credentials: Mapping[str, str], case: Case,
    status: int | None, out: str, err: str, requests: Sequence[Document],
) -> None:
    """Compare one run's whole public boundary with the pair; each failed assertion prints what differed."""
    leaked = [text for content in credentials.values() for text in credential_strings(content) if text and (text in out or text in err)]
    test.assertEqual(leaked, [], "a credential reached stdout or stderr")
    test.assertEqual(len(requests), len(case.scenario.replies), "requests sent")
    test.assertEqual(requests, case.expected.requests, "requests")
    test.assertEqual(public_result(status, out, err), case.expected.result, f"result (exit {status}, stdout {out!r}, stderr {err!r})")


def conformance(directory: Path, entry: str, selector: str = "all") -> unittest.TestSuite:
    """Return one test per selected case, each named by its scenario and transport, for the Reader at `entry`."""
    pair = Pair.read(directory)

    class Conformance(unittest.TestCase):
        """A failed assertion names its case and prints the whole objects that differed."""

        maxDiff = None
        inputs: Inputs
        case: Case

        def test_replay(self) -> None:
            """Run the actual command and compare its whole public boundary with the pair."""
            inputs, case = self.inputs, self.case
            credentials = inputs.credentials | case.scenario.credentials
            network = ScriptedNetwork(inputs.now, [inputs.replies[name] for name in case.scenario.replies])
            with TemporaryDirectory() as tmp:
                env = case_environment(Path(tmp), inputs, case.scenario)
                with (
                    patch.dict(sys.modules),
                    patch.dict(os.environ, env, clear=True),
                    patch("urllib3.request", network.request),
                    captured_stream(1) as stdout,
                    captured_stream(2) as stderr,
                ):
                    module, _, name = entry.partition(":")
                    command = cast(Entry, getattr(import_module(module), name))
                    self.assertEqual((stdout.tell(), stderr.tell()), (0, 0), "the Reader wrote while importing")
                    status = command(env, network.clock)
                    stdout.seek(0)
                    stderr.seek(0)
                    out, err = stdout.read(), stderr.read()
            compare(self, credentials, case, status, out, err, network.requests)

    cases = pair.cases.values() if selector == "all" else [pair.cases[selector]]
    return unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(type(case.name, (Conformance,), {"inputs": pair.inputs, "case": case}))
        for case in cases
    )
