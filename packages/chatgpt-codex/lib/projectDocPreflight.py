"""Warn locally about Codex project documents and config, without starting Codex."""

import json
from pathlib import Path
import subprocess
import sys


def discovery_options(arguments, flags):
    # Use extracted value requirements to skip values of unrelated flags (a model or
    # output filename must not be mistaken for a discovery option). Prompt
    # text is one argv entry; the explicit -- separator ends option parsing.
    options = []
    index = 0
    relevant = {"-C", "--cd", "-c", "--config", "-p", "--profile"}
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            break
        if not argument.startswith("-") or argument == "-":
            index += 1
            continue
        flag, equals, value = argument.partition("=")
        if flag not in flags and argument[:2] in flags and flags[argument[:2]]:
            flag, value = argument[:2], argument[2:]
            equals = "="
        if flag in {"--remote", "--worktree"}:
            # These sessions discover docs elsewhere, after launch. A local
            # filesystem check cannot predict their effective directories.
            return None
        if flag not in flags:
            # A new/unknown flag may consume a discovery-looking value. Do not
            # guess at that unsupported input; the real CLI will handle it.
            return None
        if flags[flag] and not equals:
            index += 1
            value = arguments[index]
        if flag in relevant:
            options.extend([flag, value])
        index += 1
    return options


def main():
    resolver, schema, trust_notice, permission_notice, *arguments = sys.argv[1:]
    with open(schema) as source:
        options = discovery_options(arguments, json.load(source))
    if options is None:
        return
    cwd = "."
    config_options = []
    for index in range(0, len(options), 2):
        option, value = options[index:index + 2]
        if option in {"-C", "--cd"}:
            cwd = value
        else:
            config_options.extend([option, value])
    result = subprocess.run(
        [resolver, cwd, "32768", "--json", *config_options],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=0.5,
        check=True,
    )
    resolution = json.loads(result.stdout)
    # Document warnings first: the notices below start a process per project
    # config, and the launcher's one-second bound must not cut these short.
    document_warnings(resolution)
    # Every project config layer Codex would load from this launch: the trust
    # notice warns when Codex will ignore it, the permission notice when its
    # model opposes the user's. The user config is skipped where the walk
    # reaches CODEX_HOME's parent, as the resolver skips it. Trust comes from
    # the resolution above, not one more resolver run per directory.
    for directory in resolution["directories"]:
        config = Path(directory) / ".codex/config.toml"
        if config.is_file() and str(config) != resolution["user_config"]:
            subprocess.run([trust_notice, directory, resolution["directory_trust"][directory]], check=False)
            subprocess.run([permission_notice, str(config)], check=False)


def document_warnings(resolution):
    # Explicitly untrusted projects suppress project instructions upstream;
    # an undecided project still reads docs but ignores project config.
    if resolution["untrusted"]:
        return
    remaining = resolution["limit"]
    missing = []
    for directory in resolution["directories"]:
        for name in resolution["filenames"]:
            path = Path(directory) / name
            if not path.is_file():
                continue
            try:
                data = path.read_bytes()
            except OSError:
                break
            # The first existing candidate wins, even an empty override.
            if data.decode("utf-8", errors="replace").strip() and len(data) > remaining:
                missing.append((path, len(data)))
            # Whitespace-only content does not consume Codex's byte budget.
            if data[:remaining].decode("utf-8", errors="replace").strip():
                remaining = max(0, remaining - len(data))
            break
    if not missing:
        return
    for path, size in missing:
        print(
            f"warning: {path} is {size} bytes; project docs exceed Codex's "
            f"project_doc_max_bytes ({resolution['limit']} bytes total). Codex truncates or omits their content. "
            "Raise project_doc_max_bytes (ai.codex.projectDocMaxBytes), or shrink the project docs.",
            file=sys.stderr,
        )
    if resolution["untrusted_config"]:
        print(
            f"warning: {resolution['untrusted_config']} raises project_doc_max_bytes, "
            f"but its project must be trusted in {resolution['user_config']} for Codex to apply it.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    # Advisory only: unreadable files, invalid config, unsupported CLI inputs,
    # resolver errors and timeouts must never prevent the real Codex launch.
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError):
        pass
