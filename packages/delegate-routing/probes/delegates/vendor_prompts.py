#!/usr/bin/env python3
"""Regenerate the committed reference copies of each harness's vendor base prompt.

usage: python3 packages/delegate-routing/probes/delegates/vendor_prompts.py [harness...]

Runs each harness's existing OFFLINE capture case (no account, no quota), extracts
the vendor-authored text the model receives, scrubs machine-specific values to
stable placeholders and writes docs/delegates/vendor-prompts/<harness>.md.

Harnesses: claude, codex, kimchi, kiro. Scratch goes to a fresh
/var/tmp/vp-<harness>.XXXXXX dir that is removed afterwards; set VP_KEEP=1 to keep it.
CLAUDE_BIN, CODEX_PKG, KIMCHI_PKG and KIRO_PKG skip the nix builds.
"""

import datetime
import getpass
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent.parent
OUT_DIR = PKG / "docs" / "delegates" / "vendor-prompts"
REGEN = "python3 packages/delegate-routing/probes/delegates/vendor_prompts.py"

sys.path.insert(0, str(HERE / "common"))
import pin  # noqa: E402


def slug(path):
    """Claude's project-dir form of a path: every non-alphanumeric char becomes '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def scrub(text, work, extra=()):
    """Replace machine- and run-specific values with stable placeholders.

    `extra` holds a harness's own (pattern, placeholder) rules, applied last.
    """
    pairs = [(work, "<work>"), (slug(work), "<work-slug>")]
    home = str(Path.home())
    pairs += [(home, "<home>"), (slug(home), "<home-slug>")]
    pairs += [(getpass.getuser(), "<user>"), (socket.gethostname(), "<host>")]
    for raw, placeholder in sorted(pairs, key=lambda p: -len(p[0])):
        if raw:
            text = text.replace(raw, placeholder)
    rules = [
        (r"\bcch=[0-9a-f]+", "cch=<cch>"),
        (r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<uuid>"),
        (r"/nix/store/[0-9a-z]{32}-", "/nix/store/<hash>-"),
        (re.escape(datetime.date.today().isoformat()), "<date>"),
        *extra,
    ]
    for pattern, placeholder in rules:
        text = re.sub(pattern, placeholder, text)
    return text


def fence(text):
    """A backtick fence longer than any backtick run inside the text."""
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def wrap(lines):
    """Fill prose and list lines to 80 columns the way prettier's proseWrap does.

    Inline code spans never break, so their spaces are held as NUL while filling.
    """
    out = []
    for line in lines:
        lead = "- " if line.startswith("- ") else ""
        body = re.sub(r"`[^`]*`", lambda m: m.group(0).replace(" ", "\0"), line[len(lead) :])
        filled = textwrap.fill(
            body,
            80,
            initial_indent=lead,
            subsequent_indent=" " * len(lead),
            break_long_words=False,
            break_on_hyphens=False,
        )
        out.append(filled.replace("\0", " ") if body else "")
    return "\n".join(out)


def block(label, text):
    """A fenced verbatim block. prettier trims trailing whitespace even inside a fence,
    so a body that carries any is marked `prettier-ignore` to keep it byte-exact."""
    f = fence(text)
    ignore = "<!-- prettier-ignore -->\n" if re.search(r"[ \t]$", text, re.M) else ""
    return f"### {label}\n\n{ignore}{f}text\n{text}\n{f}\n"


def page(title, bullets, notes, blocks):
    """A vendor-prompt page: title, metadata bullets (regenerate last), notes, then the blocks."""
    head = [f"# {title}", "", *(f"- {b}" for b in bullets), f"- regenerate: `{REGEN}`", ""]
    for note in notes:
        head += [note, ""]
    return wrap(head) + "\n" + "\n".join(blocks)


def pinned(attr):
    """Store path and version of the repository-pinned package `attr`."""
    pkg = pin.package(attr)
    return pkg, re.search(r"-(\d+\.\d+\.\d+)$", pkg.name).group(1)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_quiet(argv, env):
    subprocess.run([str(a) for a in argv], env=env, check=True, stdout=subprocess.DEVNULL)


def claude(work):
    case = "cache1p-none"
    capture = HERE / "claude" / "sysprompt" / "capture.sh"
    run_quiet([capture, case], dict(os.environ, PROBE_OUT=str(work)))
    cdir = work / "claude-sysprompt" / case
    req = json.loads((cdir / "req-001.json").read_text())["body"]
    root = str(work / "claude-sysprompt")
    system = req["system"]
    header = system[0]["text"]
    version = re.search(r"cc_version=(\d+\.\d+\.\d+)", header).group(1)
    cmd = (cdir / "cmd").read_text().strip()
    blocks = []
    for i, s in enumerate(system):
        cc = s.get("cache_control")
        label = f"system[{i}]" + (f" (cache_control {json.dumps(cc, sort_keys=True)})" if cc else "")
        blocks.append(block(label, scrub(s["text"], root)))
    bullets = [
        "harness: Claude Code CLI (`claude-code`)",
        f"pinned version: {version}",
        f"launcher: `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1 {cmd}` against the"
        " offline Messages mock (`probes/delegates/claude/sysprompt/capture.sh`)",
        f"capture case: `{case}` (main session, no append, no fixture text in `system`)",
    ]
    notes = [
        "Every block of the request's `system` array, verbatim in order. The"
        " first-party layout splits the static and dynamic halves into `system[2]` and"
        " `system[3]`. Placeholders: `<work>` and `<work-slug>` stand for the scratch"
        " directory and Claude's project-dir form of it; `<cch>` and `<uuid>` for the"
        " per-request billing hash and prompt id.",
        "Not included: the `<system-reminder>` user-message blocks (environment, model,"
        " date, git status, skills and agents), which mix vendor templates with the"
        " fixture's own text.",
    ]
    return page("Claude Code vendor system prompt", bullets, notes, blocks)


def codex(work):
    case, sentinel = "wireA", "MAIN-A-2001"
    pkg, version = pinned("chatgpt-codex")
    root = work / "codex-sysprompt"
    root.mkdir()
    # wire.sh builds the catalog through `nix build` itself; doing it here keeps that
    # off the isolated HOME below, which stops ~/.agents/skills reaching the skills block.
    run_quiet([sys.executable, HERE / "codex" / "mkcache.py", pin.source("chatgpt-codex"), root / "models_cache.json"], os.environ)
    (work / "home").mkdir()
    env = dict(os.environ, PROBE_OUT=str(work), HOME=str(work / "home"), CODEX_PKG=str(pkg))
    run_quiet([HERE / "codex" / "sysprompt" / "wire.sh", case, free_port()], env)
    (path,) = sorted((root / case).glob("req00-root-*.json"))
    req = json.loads(path.read_text())
    if req.get("instructions"):
        sys.exit(f"codex: unexpected `instructions` field in {path.name}")
    blocks, dropped = [], 0
    for k, item in enumerate(req["input"]):
        if item.get("type") != "message" or item.get("role") != "developer":
            continue
        for j, part in enumerate(item["content"]):
            if part["text"] == sentinel:
                dropped += 1
                continue
            if sentinel in part["text"]:
                sys.exit(f"codex: fixture sentinel inside input[{k}].content[{j}]")
            blocks.append(block(f"input[{k}].content[{j}] (developer)", scrub(part["text"], str(root))))
    if dropped != 1:
        sys.exit(f"codex: expected the config developer_instructions part once, found {dropped}")
    bullets = [
        "harness: Codex CLI (`chatgpt-codex`)",
        f"pinned version: {version}",
        "launcher: `codex --no-daemon debug app-server send-message-v2 TRIGGER` with model"
        f" `{req['model']}` from the bundled catalog, against the offline scripted Responses"
        " provider (`probes/delegates/codex/sysprompt/wire.sh`)",
        f"capture case: `{case}`, first root request (`{path.name}`); the run's HOME is an"
        " empty scratch directory",
    ]
    notes = [
        "Every developer-role message part of the root agent's first request, verbatim in"
        " order. The request's `instructions` field is empty: the model's base"
        " instructions travel as `input[1]`, and they are selected per model, so another"
        " catalog model can receive a different base. Placeholders: `<work>` stands for"
        " the scratch directory, whose `home-wireA` is the run's `CODEX_HOME`.",
        "Not included: `input[2].content[0]`, the case's own config"
        f" `developer_instructions` (`{sentinel}`); the `additional_tools` item (tool"
        " definitions); the `<environment_context>` user message (cwd, shell, date,"
        " timezone and sandbox profile of the run) and the trigger text. The case"
        " declares two roles (`r1`, `r2`); their descriptions reach only the tool"
        " definitions, not these messages.",
    ]
    return page("Codex vendor base prompt", bullets, notes, blocks)


def kiro(work):
    case, user = "w-v3", "hello USER_SENTINEL_1"
    pkg, version = pinned("kiro-cli.unwrapped")
    env = dict(os.environ, PROBE_OUT=str(work), KIRO_PKG=str(pkg), T="90")
    argv = ["chat", "--v3", "--no-interactive", "-a", user]
    run_quiet([HERE / "kiro" / "wire2.sh", case, "--", *argv], env)
    run = work / "kiro" / case / "run"
    rows = [json.loads(line) for line in (run / "wire.jsonl").read_text().splitlines()]
    req = next(r for r in rows if r.get("target") == "KiroRuntimeService.GenerateAssistantResponse" and "body" in r)
    body = json.loads(req["body"]) if isinstance(req["body"], str) else req["body"]
    kas = re.search(r"KAS/(\S+)", req["headers"]["x-amz-user-agent"]).group(1)
    state = body["conversationState"]
    h0 = state["history"][0]["userInputMessage"]["content"]
    ack = state["history"][1]["assistantResponseMessage"]["content"]
    current = state["currentMessage"]["userInputMessage"]["content"]
    at = h0.index("You are Kiro")
    rules, base = h0[:at], h0[at:]
    # Each steering file arrives in a vendor wrapper; keep the first global and the first
    # workspace one, with the fixture file's name and body replaced by placeholders.
    wrappers = {}
    for m in re.finditer(r"## Included Rules \((.+?)\) \[(\w+)\]\n.*?</user-rule>", rules, re.S):
        name, scope = m.groups()
        text = m.group(0).replace(f"({name})", "(<name>)").replace(f"id={name}>", "id=<name>>")
        wrappers.setdefault(scope, re.sub(r"\b[A-Z_]+_SENTINEL\b", "<file body>", text))
    if sorted(wrappers) != ["Global", "Workspace"]:
        sys.exit(f"kiro: steering wrappers found: {sorted(wrappers)}")
    before, sep, after = current.partition(user)
    if not sep:
        sys.exit("kiro: user text not found in currentMessage")
    extra = [
        (r"Date: [A-Z][a-z]+ \d{1,2}, \d{4}", "Date: <date>"),
        (r"Day of Week: [A-Za-z]+", "Day of Week: <weekday>"),
    ]
    parts = [
        ("history[0] steering wrapper, global (`~/.kiro/steering`)", wrappers["Global"]),
        ("history[0] steering wrapper, workspace (`.kiro/steering`, AGENTS.md)", wrappers["Workspace"]),
        ("history[0] KAS base", base),
        ("history[1] (assistant)", ack),
        ("currentMessage before the user text", before),
        ("currentMessage after the user text", after),
    ]
    blocks = []
    for label, text in parts:
        text = scrub(text, str(run), extra)
        if "SENTINEL" in text:
            sys.exit(f"kiro: fixture sentinel left in {label}")
        blocks.append(block(label, text))
    bullets = [
        "harness: Kiro CLI (`kiro-cli`), v3 engine",
        f"pinned version: {version} (KAS {kas})",
        f"launcher: `kiro-cli-chat {' '.join(argv[:-1])} \"{user}\"` in an empty network"
        " namespace against the offline capture server (`probes/delegates/kiro/wire2.sh`)",
        f"capture case: `{case}` (headless main session, the binary's default agent)",
    ]
    notes = [
        "The vendor text of the first `GenerateAssistantResponse` request. KAS sends no"
        " system field: the base prompt is the tail of the synthetic first user turn"
        " (`history[0]`), after one wrapper per steering file, and the vendor's"
        " acknowledgement is `history[1]`. The current user message wraps the user's text"
        " in a session-context prefix and an editor-context suffix. Placeholders:"
        " `<work>` stands for the run directory, whose `home` and `ws` are the run's HOME"
        " and workspace; `<date>` and `<weekday>` for the run date; `<name>` and"
        " `<file body>` for the steering file's name and text.",
        "The workspace file tree in `<session_start_snapshot>` lists the probe's own"
        " fixture workspace (its AGENTS.md, CLAUDE.md, README.md and `nested/`)."
        " Not included: the fixture's steering bodies and the user text; the tool"
        " definitions. This capture carries no progress or hook-output blocks.",
    ]
    return page("Kiro vendor base prompt", bullets, notes, blocks)


def kimchi(work):
    pkg, version = pinned("kimchi")
    argv = ["--model", "kimchi-dev/fake-a", "--mode", "json", "--approve", "-p", "hi"]
    scenario = work / "main.json"
    scenario.write_text(json.dumps({"full_wire": True, "timeout": 30, "args": argv}))
    out = work / "main"
    run_quiet([sys.executable, HERE / "kimchi" / "live" / "drive.py", scenario, out], dict(os.environ, KIMCHI_PKG=str(pkg)))
    base = json.loads((out / "meta.json").read_text())["base"]
    rows = [json.loads(line) for line in (out / "wire.jsonl").read_text().splitlines()]
    main = [r for r in rows if str(r["messages"][0].get("content", "")).startswith("You are Kimchi")]
    if len(main) != 1:
        sys.exit(f"kimchi: expected one main request, found {len(main)}")
    first = main[0]["messages"][0]
    if first["role"] not in ("developer", "system") or not isinstance(first["content"], str):
        sys.exit(f"kimchi: unexpected first message shape: role {first['role']}")
    extra = [(r"(?m)^- OS version: .*$", "- OS version: <os-version>")]
    blocks = [block(f"messages[0] ({first['role']})", scrub(first["content"], base, extra))]
    bullets = [
        "harness: Kimchi CLI (`kimchi`)",
        f"pinned version: {version}",
        f"launcher: `kimchi {' '.join(argv)}` against the offline fake gateway"
        " (`probes/delegates/kimchi/live/drive.py` with `fakeprov.py`)",
        "capture case: `-p` main session in the shape of `claude:sp-p01-print-all`, with"
        " no context files, hooks, agents, extensions or appended prompt",
    ]
    notes = [
        "The system message Kimchi rebuilds for the main request, verbatim. It is sent"
        " in the `developer` role because the fake catalog advertises `fake-a` as a"
        " reasoning model; `fake-a` in the single-model section is the fixture model id."
        " Placeholders: `<work>` stands for the run's scratch base, whose `home` and"
        " `project` are HOME and the working directory; `<hash>` for the store hash;"
        " `<date>` and `<os-version>` for the run date and the host kernel. Shell and"
        " username read `unknown` because the run's environment sets neither.",
        "Not included: the user message (`hi`) and the tool definitions.",
    ]
    return page("Kimchi vendor base prompt", bullets, notes, blocks)


HARNESSES = {"claude": claude, "codex": codex, "kimchi": kimchi, "kiro": kiro}


def main(argv):
    names = argv or sorted(HARNESSES)
    unknown = [n for n in names if n not in HARNESSES]
    if unknown:
        sys.exit(f"unknown harness: {', '.join(unknown)} (known: {', '.join(sorted(HARNESSES))})")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name in names:
        work = Path(tempfile.mkdtemp(prefix=f"vp-{name}.", dir="/var/tmp"))
        try:
            text = HARNESSES[name](work)
        finally:
            if os.environ.get("VP_KEEP") != "1":
                shutil.rmtree(work, ignore_errors=True)
        dest = OUT_DIR / f"{name}.md"
        dest.write_text(text)
        print(f"{dest.relative_to(PKG.parent.parent)} {len(text.encode())} bytes")


if __name__ == "__main__":
    main(sys.argv[1:])
