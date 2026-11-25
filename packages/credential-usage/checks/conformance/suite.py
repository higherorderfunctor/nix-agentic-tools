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


class Reply(FixtureModel):
    """Deliver the scripted status and literal HTTP response text."""
    status: Annotated[int, Field(ge=100, le=599)]
    body: str
    private: bool = False


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

    def changes_on(self, transport: TransportName) -> Document:
        """Return what the entry changes on one transport: the shared fields, then that transport's own."""
        return merged(cast(Document, self.model_extra), self.cpa if transport == "cpa" else self.direct)


def expanded(entries: Mapping[str, CaseEntry], transports: Sequence[TransportName]) -> dict[str, dict[TransportName, Document]]:
    """Return each entry's complete object on every transport, expanded from the full case it extends."""
    objects: dict[str, dict[TransportName, Document]] = {}
    for name, entry in entries.items():
        if entry.extends is None:
            objects[name] = {transport: entry.changes_on(transport) for transport in transports}
    for name, entry in entries.items():
        if entry.extends is not None:
            objects[name] = {transport: merged(objects[entry.extends][transport], entry.changes_on(transport)) for transport in transports}
    return objects


class Inputs(FixtureModel):
    """Read the shared supplies and each scenario from input.json."""

    description: str
    transports: Annotated[list[TransportName], Field(min_length=1)]
    now: datetime
    replies: dict[str, Reply]
    credentials: CredentialFiles
    executables: dict[FileName, str]
    scenarios: Annotated[dict[FileName, CaseEntry], Field(min_length=1)]

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


def invalid_fields(error: ValidationError) -> str:
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
        scenario_objects = expanded(inputs.scenarios, inputs.transports)
        expected_objects = expanded(expectations, inputs.transports)
        cases: dict[str, Case] = {}
        for name in inputs.scenarios:
            for transport in inputs.transports:
                key = f"{name}/{transport}"
                try:
                    scenario = Scenario.model_validate(scenario_objects[name][transport])
                    expectation = Expected.model_validate(expected_objects[name][transport])
                except ValidationError as error:
                    raise IncompletePair(f"{key}: {invalid_fields(error)}") from None
                if any(reply not in inputs.replies for reply in scenario.replies):
                    raise IncompletePair(f"{key}: unknown reply")
                cases[key] = Case(key, scenario, expectation)
        return cls(inputs, cases)


class PrivateContent(NamedTuple):
    """What one private document keeps out of a diagnostic: its text spellings and the objects and arrays its JSON parses to."""

    spellings: frozenset[str]
    trees: tuple[JsonValue, ...]


def private_content(text: str) -> PrivateContent:
    """Collect the literal text, each string inside its JSON and each non-empty object or array its JSON parses to, nested JSON text included."""
    if not text:
        return PrivateContent(frozenset(), ())
    spellings = {text}
    if text.strip() and text.strip() != text:
        spellings.add(text.strip())
    try:
        parsed = TypeAdapter(JsonValue).validate_json(text)
    except ValidationError:
        return PrivateContent(frozenset(spellings), ())
    trees: list[JsonValue] = [parsed] if isinstance(parsed, dict | list) and parsed else []
    for value in string_values(parsed):
        deeper = private_content(value)
        spellings |= deeper.spellings
        trees += deeper.trees
    return PrivateContent(frozenset(spellings), tuple(trees))


def string_values(value: JsonValue) -> Iterator[str]:
    """Yield each non-empty string the JSON object or array carries as a value, at any depth."""
    if isinstance(value, str) and value:
        yield value
    elif isinstance(value, dict):
        for part in value.values():
            yield from string_values(part)
    elif isinstance(value, list):
        for part in value:
            yield from string_values(part)


def same_json(left: JsonValue, right: JsonValue) -> bool:
    """Compare JSON values without treating true as 1 or false as 0 in Python."""
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(same_json(value, right[key]) for key, value in left.items())
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(same_json(a, b) for a, b in zip(left, right))
    return isinstance(left, bool) == isinstance(right, bool) and left == right


def carries(value: JsonValue, tree: JsonValue) -> bool:
    """Tell whether a JSON object or array holds every member of a private object or array."""
    if isinstance(tree, dict) and isinstance(value, dict):
        return tree.keys() <= value.keys() and all(same_json(value[key], member) for key, member in tree.items())
    if isinstance(tree, list) and isinstance(value, list):
        return all(any(same_json(element, member) for element in value) for member in tree)
    return False


class Redaction(NamedTuple):
    """Replace what one case keeps private: each credential by its file name, each failed or private reply by `[private]`."""

    credential_text: Callable[[str], str]
    private_text: Callable[[str], str]
    private_json: Callable[[JsonValue], JsonValue]
    spellings: tuple[str, ...]


def redaction(credentials: CredentialFiles, replies: Sequence[Reply]) -> Redaction:
    """Collect from each credential file and each failed or private reply what a diagnostic must replace, and with what."""
    credential_marks: dict[str, str] = {}
    reply_marks: dict[str, str] = {}
    documents = [(f"[credential:{name}]", content, credential_marks) for name, content in credentials.items()]
    documents += [("[private]", reply.body, reply_marks) for reply in replies if reply.private or not 200 <= reply.status < 300]
    trees: list[tuple[JsonValue, str]] = []
    for placeholder, body, marks in documents:
        content = private_content(body)
        for value in content.spellings:
            for spelling in (value, json.dumps(value)[1:-1]):
                marks[spelling] = placeholder
        trees += [(tree, placeholder) for tree in content.trees]

    def private_json(value: JsonValue) -> JsonValue:
        """Replace each object or array that carries a private one with its placeholder, and recurse into the others."""
        placeholder = next((mark for tree, mark in trees if carries(value, tree)), None)
        if placeholder is not None:
            return placeholder
        if isinstance(value, dict):
            return {key: private_json(part) for key, part in value.items()}
        if isinstance(value, list):
            return [private_json(part) for part in value]
        return value

    return Redaction(
        credential_text=conceal(credential_marks),
        private_text=conceal(credential_marks | reply_marks),
        private_json=private_json,
        spellings=tuple(credential_marks | reply_marks),
    )


def conceal(values: Mapping[str, str]) -> Callable[[str], str]:
    """Return a function that swaps each key for its value, longest first, so no diagnostic repeats a private string."""
    if not values:
        return lambda text: text
    pattern = re.compile("|".join(map(re.escape, sorted(values, key=len, reverse=True))))

    def swap(text: str) -> str:
        return pattern.sub(lambda match: values[match[0]], text)

    return swap


class ScriptedNetwork:
    """Serve one reply per HTTP call and stamp observations with the completed call count."""

    def __init__(self, start: datetime, replies: list[Reply], credential_text: Callable[[str], str]):
        self.start = start
        self.replies = replies
        self.credential_text = credential_text
        self.requests: list[Request] = []

    def clock(self) -> datetime:
        return self.start + timedelta(seconds=len(self.requests))

    def request(
        self, method: str, url: str, *, headers: dict[str, str] | None = None,
        body: str | None = None, **_: object,
    ) -> HTTPResponse:
        """Record before replying so even a Reader that catches an extra request fails its case."""
        payload: JsonValue = None
        if body is not None:
            try:
                payload = TypeAdapter(JsonValue).validate_json(self.credential_text(body))
            except ValidationError:
                payload = self.credential_text(body)
        self.requests.append(Request(
            method=self.credential_text(method), url=self.credential_text(url),
            headers={self.credential_text(k): self.credential_text(v) for k, v in (headers or {}).items()}, body=payload,
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


class PublicOutput(NamedTuple):
    """A command's public output: what its consumer accepts, and the JSON object it printed, a valid envelope or not."""

    accepted: Document | None
    printed: Document | None


def public_result(status: int | None, out: str, err: str) -> PublicOutput:
    """Read stdout as the command's consumer does: one envelope, or one public failure line, or nothing accepted."""
    if status != 0:
        if status is not None and not out and re.fullmatch(r"usage: [^\r\n]+\n", err):
            return PublicOutput({"failed": err[:-1]}, None)
        return PublicOutput(None, None)
    try:
        printed = TypeAdapter(Document).validate_json(out, strict=True)
    except ValidationError:
        return PublicOutput(None, None)
    try:
        Envelope.model_validate(printed)
    except ValidationError:
        # An object that is not an envelope is no result for the consumer; a diff still shows what was printed.
        return PublicOutput(None, printed)
    return PublicOutput(printed, printed)


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


def diff_of(expected: JsonValue, observed: JsonValue, redactor: Redaction) -> str:
    """Diff copies of the complete expected and observed objects with every private spelling, object and array replaced; the comparison keeps the originals."""

    def rendered(value: JsonValue) -> str:
        return redactor.private_text(json.dumps(whole_numbers(redactor.private_json(value)), indent=2, sort_keys=True))

    before, after = rendered(expected).splitlines(), rendered(observed).splitlines()
    return "\n".join(unified_diff(before, after, "expected", "observed", n=len(before), lineterm=""))


def result_difference(case: str, expected: JsonValue, output: PublicOutput, redactor: Redaction) -> Difference | None:
    """Compare a whole public result; when the consumer accepted nothing, diff the object that was printed instead."""
    if same_json(output.accepted, expected):
        return None
    return Difference(f"{case}: result", diff_of(expected, output.accepted if output.accepted is not None else output.printed, redactor))


def differences(inputs: Inputs, case: Case, entry: str) -> list[Difference]:
    """Run the actual command and return one safe report for every failed comparison."""
    errors: list[Difference] = []
    replies = [inputs.replies[name] for name in case.scenario.replies]
    credentials = inputs.credentials | case.scenario.credentials
    redactor = redaction(credentials, replies)
    network = ScriptedNetwork(inputs.now, replies, redactor.credential_text)
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

    if any(secret in stream for stream in (out, err) for secret in redactor.spellings):
        errors.append(Difference(f"{case.name}: leak"))
    if len(network.requests) != len(replies):
        errors.append(Difference(f"{case.name}: extra request" if len(network.requests) > len(replies) else f"{case.name}: missing request"))
    expected_trace: JsonValue = [request.model_dump() for request in case.expected.requests]
    trace: JsonValue = [request.model_dump() for request in network.requests]
    if not same_json(trace, expected_trace):
        errors.append(Difference(f"{case.name}: trace", diff_of(expected_trace, trace, redactor)))
    result = result_difference(case.name, case.expected.result, public_result(status, out, err), redactor)
    if result is not None:
        errors.append(result)
    return errors
