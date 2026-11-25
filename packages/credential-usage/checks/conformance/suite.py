# pyright: strict
# cspell:ignore lineterm
"""Fill owners replay their paired fixtures here to compare the entire Reader command boundary.

Both files of a pair list the same scenarios. An entry writes once what both transports share (the
fields beside `extends`) and writes under `direct` or `cpa` what one transport alone changes. One
merge rule joins the two, then joins them onto the full case the entry `extends`: objects merge by
key; arrays and scalars replace. A full case (`"extends": null`) has nothing beneath it, so what it
writes must be complete on every declared transport.

A failed comparison prints a diagnostic under one public display contract, which both runners share:

- D1. Nothing private appears in any form. No member of a credential file, or of a reply that is
  `private` or not a 2xx, appears in a printed diagnostic: not as a whole value, not as a key,
  string, number or boolean at any depth, not as a member of JSON carried inside a string, and not
  re-serialized with other whitespace or key order.
- D2. Masking is per member. Hiding a private member never hides the object, array or public sibling
  around it. A public field that explains a failure stays visible.
- D3. A failed comparison never prints an empty diff. When two sides differ only in withheld members,
  the report names each path whose values were withheld and says they differ.
- D4. The comparison keeps the originals. Masking happens only in the copy that is rendered, in both
  runners, for the request trace and for the result.
"""

from collections.abc import Callable, Generator, Iterable, Mapping, Sequence
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta
from difflib import unified_diff
from functools import reduce
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
Scalar = str | int | float | bool


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


class PrivateMembers(NamedTuple):
    """What the private documents of one case keep out of a diagnostic: every string, key, number and boolean, each with the text that replaces it."""

    strings: dict[str, str]
    keys: dict[str, str]
    numbers: dict[float, str]
    truths: dict[bool, str]

    def joined(self, other: "PrivateMembers") -> PrivateMembers:
        """Return the members of two private documents."""
        return PrivateMembers(self.strings | other.strings, self.keys | other.keys, self.numbers | other.numbers, self.truths | other.truths)

    def withheld(self, value: Scalar) -> str | None:
        """Return the text that replaces a scalar equal to a private string, key, number or boolean; None when it may be shown."""
        if isinstance(value, bool):
            return self.truths.get(value)
        if isinstance(value, str):
            return self.strings.get(value) or self.keys.get(value)
        return self.numbers.get(value)


NO_MEMBERS = PrivateMembers({}, {}, {}, {})


def same_json(left: JsonValue, right: JsonValue) -> bool:
    """Compare JSON values without treating true as 1 or false as 0 in Python."""
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(same_json(value, right[key]) for key, value in left.items())
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(same_json(a, b) for a, b in zip(left, right))
    return isinstance(left, bool) == isinstance(right, bool) and left == right


def collected(parts: Iterable[PrivateMembers]) -> PrivateMembers:
    """Return the members of several private documents."""
    return reduce(PrivateMembers.joined, parts, NO_MEMBERS)


def json_inside(text: str) -> JsonValue | None:
    """Return the JSON value a string carries, or None when it carries none or carries null."""
    try:
        return TypeAdapter(JsonValue).validate_json(text)
    except ValidationError:
        return None


def json_members(value: JsonValue | None, placeholder: str) -> PrivateMembers:
    """Collect every key and every string, number and boolean of a parsed private document, entering JSON carried in a string. Null carries nothing to hide."""
    if isinstance(value, bool):
        return PrivateMembers({}, {}, {}, {value: placeholder})
    if isinstance(value, str):
        return private_members(value, placeholder)
    if isinstance(value, int | float):
        return PrivateMembers({}, {}, {value: placeholder}, {})
    if isinstance(value, dict):
        return collected(
            PrivateMembers({}, {key: placeholder}, {}, {}).joined(json_members(member, placeholder))
            for key, member in value.items()
        )
    if isinstance(value, list):
        return collected(json_members(member, placeholder) for member in value)
    return NO_MEMBERS


def private_members(text: str, placeholder: str) -> PrivateMembers:
    """Collect what one private document keeps out of a diagnostic: its whole text, then every key and scalar of the JSON it parses to, at any depth."""
    if not text:
        return NO_MEMBERS
    strings = {text: placeholder}
    stripped = text.strip()
    if stripped and stripped != text:
        strings[stripped] = placeholder
    return PrivateMembers(strings, {}, {}, {}).joined(json_members(json_inside(text), placeholder))


class Redaction(NamedTuple):
    """Replace what one case keeps private: each credential by its file name, each failed or private reply by `[private]`."""

    credential_text: Callable[[str], str]
    members: PrivateMembers
    text: Callable[[str], str]
    spellings: tuple[str, ...]

    def render(self, value: JsonValue, spell_json_text: bool = True) -> tuple[list[str], list[str]]:
        """Return the lines that display a copy of `value`, then the path of each member the copy withholds."""
        hidden: list[str] = []

        def placeholder_for(item: JsonValue, path: str) -> str | None:
            """Withhold a scalar that equals a private member and record its path; containers and null are shown."""
            if item is None or isinstance(item, dict | list):
                return None
            mark = self.members.withheld(item)
            if mark is not None:
                hidden.append(path)
            return mark

        def block(item: JsonValue, path: str, head: str, depth: int) -> str:
            """Return `item` on the lines after `head`, which ends where its value starts."""
            mark = placeholder_for(item, path)
            if mark is not None:
                return head + json.dumps(mark)
            if isinstance(item, str):
                inside = json_inside(item) if spell_json_text else None
                if isinstance(inside, dict | list):
                    return block(inside, path, f"{head.removesuffix(': ')} (JSON text): ", depth)
                return head + json.dumps(self.text(item))
            if not isinstance(item, dict | list):
                return head + json.dumps(item)
            if not item:
                return head + ("{}" if isinstance(item, dict) else "[]")
            pad = "  " * (depth + 1)
            if isinstance(item, dict):
                keyed: list[tuple[str, str]] = []
                for key in item:
                    mark = self.members.withheld(key)
                    if mark is not None:
                        # A path names a withheld key by its placeholder, so no path spells private text.
                        hidden.append(f"{path}.{mark}")
                    keyed.append((mark or self.text(key), key))
                entries = [
                    block(item[key], f"{path}.{name}", f"{pad}{json.dumps(name)}: ", depth + 1)
                    for name, key in sorted(keyed)
                ]
                opening, closing = "{", "}"
            else:
                entries = [block(member, f"{path}[{index}]", pad, depth + 1) for index, member in enumerate(item)]
                opening, closing = "[", "]"
            members = ",\n".join(entries)
            return f"{head}{opening}\n{members}\n{'  ' * depth}{closing}"

        shown = block(value, "$", "", 0)
        return shown.splitlines(), hidden


def redaction(credentials: CredentialFiles, replies: Sequence[Reply]) -> Redaction:
    """Collect from each credential file and each failed or private reply what a diagnostic must replace, and with what."""
    files = collected(private_members(content, f"[credential:{name}]") for name, content in credentials.items())
    members = files.joined(collected(
        private_members(reply.body, "[private]") for reply in replies if reply.private or not 200 <= reply.status < 300
    ))
    tokens = list(members.keys.items())
    tokens += [(json.dumps(whole_numbers(number)), mark) for number, mark in members.numbers.items()]
    tokens += [("true" if truth else "false", mark) for truth, mark in members.truths.items()]
    return Redaction(
        credential_text=conceal(files.strings),
        members=members,
        text=conceal(members.strings, tokens),
        spellings=tuple(members.strings),
    )


def conceal(strings: Mapping[str, str], tokens: Sequence[tuple[str, str]] = ()) -> Callable[[str], str]:
    """Return a function that replaces each private spelling and each private key, number or boolean standing as a whole token, longest first.

    One pass scans the original text only, so no placeholder it writes is replaced again. A private string is
    also matched in its JSON-escaped spelling, for a string carried inside a displayed key.
    """
    spellings = list(strings.items()) + [
        (json.dumps(spelling)[1:-1], mark) for spelling, mark in strings.items() if json.dumps(spelling)[1:-1] != spelling
    ]
    parts = [(spelling, re.escape(spelling), mark) for spelling, mark in spellings]
    parts += [(spelling, rf"(?<![\w.-]){re.escape(spelling)}(?![\w.-])", mark) for spelling, mark in tokens]
    if not parts:
        return lambda text: text
    marks = {spelling: mark for spelling, _, mark in reversed(parts)}
    pattern = re.compile("|".join(item for _, item, _ in sorted(parts, key=lambda part: len(part[0]), reverse=True)))
    return lambda text: pattern.sub(lambda match: marks[match[0]], text)


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
    """Diff the rendered copies of the complete expected and observed objects; when the copies are equal, name the withheld members that differ."""
    before, hidden_expected = redactor.render(whole_numbers(expected))
    after, hidden_observed = redactor.render(whole_numbers(observed))
    if before == after:
        # JSON text is displayed structurally, so a difference in its spelling alone needs the spelling displayed.
        before, _ = redactor.render(whole_numbers(expected), spell_json_text=False)
        after, _ = redactor.render(whole_numbers(observed), spell_json_text=False)
        if before == after:
            hidden = list(dict.fromkeys(hidden_expected + hidden_observed))
            return f"expected and observed differ only in withheld members at: {', '.join(hidden)}"
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
