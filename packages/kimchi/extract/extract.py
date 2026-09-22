#!/usr/bin/env python3
"""Extract Kimchi's two settings, CLI, and environment surfaces from source."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


EXTRACTOR_SCHEMA = 1


def fail(message: str) -> None:
    raise SystemExit(f"kimchi-extract: {message}")


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read {path}: {error}")


def balanced_body(text: str, anchor: str, opening: str, closing: str) -> str:
    start = text.find(anchor)
    if start < 0:
        fail(f"anchor {anchor!r} was not found")
    start = text.find(opening, start + len(anchor))
    if start < 0:
        fail(f"anchor {anchor!r} has no following {opening!r}")
    depth = 0
    quote: str | None = None
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in {'"', "'", "`"}:
            quote = char
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return text[start + 1 : index]
    fail(f"anchor {anchor!r} has an unterminated {opening}{closing} body")


def type_descriptor(type_expression: str) -> dict[str, Any]:
    expression = " ".join(type_expression.split())
    descriptor: dict[str, Any] = {"typeExpression": expression}
    literals = re.findall(r'(?<![A-Za-z0-9_])["\']([^"\']+)["\']|(?<![A-Za-z0-9_])(\d+)(?![A-Za-z0-9_])', expression)
    enum = [string or int(number) for string, number in literals]
    non_literal = re.sub(r'(?<![A-Za-z0-9_])(?:["\'][^"\']+["\']|\d+)(?![A-Za-z0-9_])', "", expression)
    non_literal = non_literal.replace("|", "").strip()
    if enum and not non_literal:
        descriptor["type"] = "enum"
        descriptor["enum"] = enum
    elif expression == "string":
        descriptor["type"] = "string"
    elif expression == "number":
        descriptor["type"] = "number"
    elif expression == "boolean":
        descriptor["type"] = "boolean"
    elif expression.endswith("[]") or expression.startswith("Array<"):
        descriptor["type"] = "array"
    elif expression.startswith("Record<") or expression.startswith("{"):
        descriptor["type"] = "object"
    elif "|" in expression:
        descriptor["type"] = "union"
        if enum:
            descriptor["enum"] = enum
    else:
        descriptor["type"] = "named"
    return descriptor


def parse_interface(text: str, name: str) -> dict[str, dict[str, Any]]:
    body = balanced_body(text, f"interface {name}", "{", "}")
    fields: dict[str, dict[str, Any]] = {}
    for match in re.finditer(
        r"^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*(\?)?\s*:\s*([^;]+);",
        body,
        re.MULTILINE,
    ):
        field, optional, type_expression = match.groups()
        fields[field] = {
            "optional": bool(optional),
            **type_descriptor(type_expression),
        }
    if not fields:
        fail(f"interface {name} had no parseable fields")
    return dict(sorted(fields.items()))


CONFIG_KEYS: dict[str, dict[str, Any]] = {
    "apiKey": {"type": "string", "project": True},
    "api_key": {"aliasFor": "apiKey", "type": "string", "project": True},
    "deviceId": {"type": "string", "project": True},
    "device_id": {"aliasFor": "deviceId", "type": "string", "project": True},
    "gitTokens": {"type": "object", "project": False},
    "llmEndpoint": {"type": "string", "project": True},
    "maxToolResultChars": {
        "inert": True,
        "project": True,
        "type": "number",
        "warning": "read only to detect obsolete configuration; it has no runtime effect",
    },
    "mcpSearch": {
        "inert": True,
        "project": True,
        "type": "object",
        "warning": "read only to detect obsolete configuration; it has no runtime effect",
        "properties": {
            "bm25B": {"type": "number"},
            "bm25K1": {"type": "number"},
            "fieldWeights": {
                "type": "object",
                "properties": {
                    "description": {"type": "number"},
                    "name": {"type": "number"},
                    "schemaKey": {"type": "number"},
                },
            },
            "strategy": {"enum": ["bm25", "regex"], "type": "enum"},
        },
    },
    "mcpSearchLimit": {
        "inert": True,
        "project": True,
        "type": "number",
        "warning": "read only to detect obsolete configuration; it has no runtime effect",
    },
    "migrationState": {"enum": ["done", "skip-forever"], "type": "enum", "project": True},
    "onboarding": {
        "project": False,
        "type": "object",
        "properties": {
            "hideSessionModeDialog": {"type": "boolean"},
            "sessionModeWizardSeenAt": {"type": "string"},
            "studioOnboardingSeenAt": {"type": "string"},
            "teleportHelpSeenAt": {"type": "string"},
        },
    },
    "preferences": {
        "project": False,
        "type": "object",
        "properties": {"hideTips": {"type": "boolean"}},
    },
    "redaction": {
        "project": True,
        "type": "object",
        "properties": {"enabled": {"type": "boolean"}},
    },
    "skillPaths": {"items": {"type": "string"}, "project": True, "type": "array"},
    "surveys": {"project": False, "type": "object"},
    "telemetry": {
        "project": False,
        "type": "object",
        "properties": {
            "enabled": {"type": "boolean"},
            "endpoint": {"type": "string"},
            "headers": {"additionalProperties": {"type": "string"}, "type": "object"},
            "metricsEndpoint": {"type": "string"},
        },
    },
    "teleport": {
        "project": False,
        "type": "object",
        "properties": {
            "compactHint": {
                "type": "object",
                "properties": {"enabled": {"type": "boolean"}},
            }
        },
    },
}


KIMCHI_HARNESS_KEYS: dict[str, dict[str, Any]] = {
    "fermentV2": {
        "type": "object",
        "properties": {
            "autoResume": {"type": "boolean"},
            "defaultTokenBudget": {"type": "integer"},
            "evaluationTimeoutMs": {"type": "integer"},
            "maxConsecutiveErrors": {"type": "integer"},
            "maxUnchangedContinuations": {"type": "integer"},
        },
    },
    "hidePhaseChanges": {"type": "boolean"},
    "modelMetadata": {
        "type": "object",
        "additionalProperties": {
            "type": "object",
            "properties": {
                "description": {"type": "string"},
                "reasoning": {"type": "boolean"},
                "tier": {"enum": ["heavy", "light", "standard"], "type": "enum"},
                "vision": {"type": "boolean"},
            },
        },
    },
    "modelRoles": {
        "type": "object",
        "properties": {
            "builder": {"typeExpression": "string | string[]", "type": "union"},
            "compactor": {"type": "string"},
            "explorer": {"typeExpression": "string | string[]", "type": "union"},
            "judge": {"typeExpression": "string | string[]", "type": "union"},
            "orchestrator": {"type": "string"},
            "planner": {"typeExpression": "string | string[]", "type": "union"},
            "researcher": {"typeExpression": "string | string[]", "type": "union"},
            "reviewer": {"typeExpression": "string | string[]", "type": "union"},
        },
    },
    "multiModel": {"type": "boolean"},
    "resources": {"additionalProperties": {"type": "boolean"}, "type": "object"},
    "shellProfileApiKeyMigrationDismissed": {"type": "boolean"},
    "statusLine": {
        "type": "object",
        "properties": {
            "command": {"type": "string"},
            "pinned": {"items": {"type": "string"}, "type": "array"},
        },
    },
    "themeAdaptive": {"type": "boolean"},
}


ENVIRONMENT_METADATA: dict[str, dict[str, Any]] = {
    "KIMCHI_ACTIVE_FERMENT": {"controls": "active ferment identifier inherited by worker processes"},
    "KIMCHI_AGENT_PERSONA": {"controls": "persona selected for an agent worker"},
    "KIMCHI_API_KEY": {"controls": "Kimchi API authentication; overrides config.json"},
    "KIMCHI_AUTO_GIT_INIT": {"controls": "automatic git initialization for ferment work"},
    "KIMCHI_CLIPBOARD_FORCE": {"controls": "clipboard backend override"},
    "KIMCHI_CODING_AGENT_DIR": {
        "consumerOverridable": False,
        "controls": "Kimchi harness configuration directory",
        "reason": "entry.ts overwrites it with ~/.config/kimchi/harness",
    },
    "KIMCHI_DAP_BINARIES": {"controls": "DAP adapter binary overrides"},
    "KIMCHI_DEBUG_PROMPTS": {"controls": "prompt debugging output"},
    "KIMCHI_DEBUG_SESSION": {"controls": "session debugging output"},
    "KIMCHI_DISABLE_BUILTIN_PROVIDERS": {
        "consumerOverridable": False,
        "controls": "suppression of pi built-in providers",
        "reason": "entry.ts overwrites it with 1",
    },
    "KIMCHI_FERMENTS_DIR": {"controls": "ferment state directory"},
    "KIMCHI_FERMENT_DISABLE_PARALLEL": {"controls": "parallel ferment execution"},
    "KIMCHI_FERMENT_LOCK_DIR": {"controls": "ferment lock directory"},
    "KIMCHI_FERMENT_LOCK_MAX_AGE_MS": {"controls": "ferment stale-lock age"},
    "KIMCHI_IDE_LOCKFILE_DIR": {"controls": "IDE lock-file directory"},
    "KIMCHI_LSP_BINARIES": {"controls": "LSP server binary overrides"},
    "KIMCHI_MCP_E2E_KEYRING_DIR": {"controls": "MCP end-to-end test keyring directory"},
    "KIMCHI_NO_PROXY": {"controls": "explicit proxy bypass list"},
    "KIMCHI_NO_UPDATE_CHECK": {"controls": "background Kimchi update check"},
    "KIMCHI_OAUTH_TEMPLATE_DIR": {
        "consumerOverridable": False,
        "controls": "OAuth result-page template directory",
        "reason": "entry.ts derives and overwrites it from PI_PACKAGE_DIR",
    },
    "KIMCHI_OLLAMA_HOST": {"controls": "Ollama host URL"},
    "KIMCHI_ORIGINAL_PI_CODING_AGENT_DIR": {"controls": "preserved inherited pi agent directory"},
    "KIMCHI_PARENT_SESSION_ID": {"controls": "parent session identity for subagents"},
    "KIMCHI_PERMISSIONS": {"controls": "initial permission mode"},
    "KIMCHI_PROXY": {"controls": "HTTP and HTTPS proxy override"},
    "KIMCHI_PROXY_HELPER": {"controls": "SSH proxy helper executable"},
    "KIMCHI_REDACTION_ENABLED": {"controls": "PII redaction override"},
    "KIMCHI_REMOTE_ENDPOINT": {"controls": "remote execution endpoint"},
    "KIMCHI_REMOTE_RUN": {"controls": "remote execution mode"},
    "KIMCHI_REVIEW_LOG": {"controls": "session-review log path"},
    "KIMCHI_REVIEW_THRESHOLD": {"controls": "session-review threshold"},
    "KIMCHI_ROUTER_ENDPOINT": {"controls": "model router endpoint"},
    "KIMCHI_SANDBOX": {"controls": "sandbox detection override"},
    "KIMCHI_SESSION_REVIEW": {"controls": "session-review enablement"},
    "KIMCHI_STREAM_IDLE_TIMEOUT_MS": {"controls": "outbound HTTP stream idle timeout"},
    "KIMCHI_SUBAGENT": {"controls": "subagent process marker"},
    "KIMCHI_TAGS": {"controls": "tags attached to LLM requests"},
    "KIMCHI_TELEMETRY_DEBUG": {"controls": "telemetry debugging output"},
    "KIMCHI_TELEMETRY_ENABLED": {"controls": "telemetry enablement override"},
    "KIMCHI_WEB_APP_URL": {"controls": "Kimchi web application base URL"},
    "PI_CACHE_RETENTION": {"controls": "provider prompt-cache retention"},
    "PI_CLEAR_ON_SHRINK": {"controls": "terminal clearing when content shrinks"},
    "PI_CODING_AGENT_DIR": {
        "consumerOverridable": False,
        "controls": "pi agent configuration directory",
        "reason": "entry.ts overwrites it with ~/.config/kimchi/harness",
    },
    "PI_CODING_AGENT_SESSION_DIR": {"controls": "pi session storage directory"},
    "PI_EXPERIMENTAL": {"controls": "pi experimental features"},
    "PI_HARDWARE_CURSOR": {"controls": "terminal hardware cursor"},
    "PI_HYPERLINKS": {"controls": "terminal hyperlink capability"},
    "PI_IMAGE_PROTOCOL": {"controls": "terminal image protocol"},
    "PI_INSTALLER_API_BASE": {"controls": "managed installer API base URL"},
    "PI_MANAGED_INSTALL_ROOT": {"controls": "managed pi installation root"},
    "PI_OAUTH_CALLBACK_HOST": {"controls": "OAuth callback bind host"},
    "PI_OFFLINE": {"controls": "pi startup network operations"},
    "PI_PACKAGE_DIR": {"controls": "pi package and runtime asset directory"},
    "PI_SHARE_VIEWER_URL": {"controls": "shared-session viewer base URL"},
    "PI_SKIP_VERSION_CHECK": {
        "consumerOverridable": False,
        "controls": "pi version check",
        "reason": "entry.ts overwrites it with 1",
    },
    "PI_STARTUP_BENCHMARK": {"controls": "interactive startup benchmark"},
    "PI_TELEMETRY": {"controls": "pi install telemetry"},
    "PI_TIMING": {"controls": "startup timing instrumentation"},
    "PI_TRUE_COLOR": {"controls": "terminal true-color capability"},
    "PI_TUI_DEBUG": {"controls": "TUI debug logging"},
    "PI_TUI_DEBUG_REDRAW": {"controls": "TUI redraw logging"},
    "PI_TUI_ESC_TIMEOUT": {"controls": "TUI escape-sequence timeout"},
    "PI_TUI_NO_CLEAR_SCROLLBACK": {"controls": "scrollback clearing in Kimchi's pi-tui patch"},
    "PI_TUI_WRITE_LOG": {"controls": "raw TUI ANSI output log path"},
}


def discover_config_keys(config_source: str) -> set[str]:
    keys = set(re.findall(r"\bparsed\??\.([A-Za-z_$][A-Za-z0-9_$]*)", config_source))
    keys.update(
        re.findall(
            r"\bparsed\??\[\s*[\"']([A-Za-z_$][A-Za-z0-9_$]*)[\"']\s*\]",
            config_source,
        )
    )
    for match in re.finditer(r"\{([^{}]+)\}\s*=\s*parsed\b", config_source):
        keys.update(
            re.findall(r"(?:^|,)\s*([A-Za-z_$][A-Za-z0-9_$]*)", match.group(1))
        )
    keys.update(re.findall(r'["\'](gitTokens|surveys|teleport)["\']', config_source))
    return keys


def extract_config(kimchi_root: Path) -> dict[str, Any]:
    source = read(kimchi_root / "src/config.ts")
    discovered = discover_config_keys(source)
    if "harness" in discovered:
        fail(
            "config.json exposes a top-level 'harness' key; this collides with the reserved harness settings namespace"
        )
    expected = set(CONFIG_KEYS)
    if discovered != expected:
        fail(
            "config.json key census changed; "
            f"new={sorted(discovered - expected)!r}, missing={sorted(expected - discovered)!r}"
        )
    return {
        "keys": dict(sorted(CONFIG_KEYS.items())),
        "projectTier": {
            "gatedByProjectTrust": True,
            "honoredKeys": sorted(key for key, value in CONFIG_KEYS.items() if value["project"]),
        },
    }


def extract_harness(kimchi_root: Path, pi_root: Path) -> dict[str, Any]:
    declaration = read(pi_root / "dist/core/settings-manager.d.ts")
    base_keys = parse_interface(declaration, "Settings")
    trust_alias = re.search(
        r'export type DefaultProjectTrust\s*=\s*([^;]+);', declaration
    )
    if not trust_alias:
        fail("pi DefaultProjectTrust type disappeared")
    trust_descriptor = type_descriptor(trust_alias.group(1))
    if trust_descriptor.get("enum") != ["ask", "always", "never"]:
        fail(f"pi DefaultProjectTrust values changed: {trust_descriptor.get('enum')!r}")
    trust_getter = read(pi_root / "dist/core/settings-manager.js")
    if 'return value === "always" || value === "never" ? value : "ask";' not in trust_getter:
        fail("pi defaultProjectTrust fallback changed")
    base_keys["defaultProjectTrust"] = {
        **base_keys["defaultProjectTrust"],
        **trust_descriptor,
        "default": "ask",
    }
    definitions = {}
    for name in [
        "BranchSummarySettings",
        "CompactionSettings",
        "ImageSettings",
        "MarkdownSettings",
        "ProviderRetrySettings",
        "RetrySettings",
        "TerminalSettings",
        "ThinkingBudgetsSettings",
        "WarningSettings",
    ]:
        definitions[name] = parse_interface(declaration, name)

    production = "\n".join(
        read(path)
        for path in sorted((kimchi_root / "src").rglob("*.ts"))
        if not path.name.endswith(".test.ts")
    )
    missing = [key for key in KIMCHI_HARNESS_KEYS if key not in production]
    if missing:
        fail(f"Kimchi harness key anchors disappeared: {missing!r}")
    overlap = set(base_keys) & set(KIMCHI_HARNESS_KEYS)
    if overlap:
        fail(f"Kimchi harness additions now overlap pi Settings: {sorted(overlap)!r}")
    keys = {
        **{key: {"source": "pi", **value} for key, value in base_keys.items()},
        **{key: {"source": "kimchi", **value} for key, value in KIMCHI_HARNESS_KEYS.items()},
    }
    return {
        "definitions": definitions,
        "keys": dict(sorted(keys.items())),
        "projectTier": {
            "gatedByProjectTrust": True,
            "supported": True,
        },
    }


def extract_kimchi_cli_options(source: str) -> dict[str, dict[str, Any]]:
    body = balanced_body(source, "export const CLI_OPTIONS", "{", "}")
    options: dict[str, dict[str, Any]] = {}
    entry = re.compile(r'^\s*(?:"([^"]+)"|([A-Za-z][A-Za-z0-9-]*))\s*:\s*\{', re.MULTILINE)
    for match in entry.finditer(body):
        name = match.group(1) or match.group(2)
        fragment = balanced_body(body[match.start() :], name, "{", "}")
        type_match = re.search(r'type:\s*"(string|boolean)"', fragment)
        description_match = re.search(r'description:\s*"((?:\\.|[^"\\])*)"', fragment, re.DOTALL)
        if not type_match or not description_match:
            fail(f"cannot parse Kimchi CLI option {name!r}")
        description = json.loads(f'"{description_match.group(1)}"')
        short_match = re.search(r'short:\s*"([^"]+)"', fragment)
        placeholder_match = re.search(r'placeholder:\s*"([^"]+)"', fragment)
        names = [f"--{name}"]
        if short_match:
            names.append(f"-{short_match.group(1)}")
        options[name] = {
            "help": description,
            "multiple": bool(re.search(r"multiple:\s*true", fragment)),
            "names": names,
            "optionalValue": bool(re.search(r"optional:\s*true", fragment)),
            "origin": ["kimchi"],
            "valueName": placeholder_match.group(1) if placeholder_match else None,
        }
    if len(options) < 20:
        fail(f"Kimchi CLI option census collapsed to {len(options)} entries")
    return options


def extract_pi_flags(pi_root: Path) -> dict[str, dict[str, Any]]:
    source = read(pi_root / "dist/cli/args.js")
    parsed_names = set(
        re.findall(r'arg\s*===\s*"(-{1,2}[A-Za-z][A-Za-z0-9-]*)"', source)
    )
    options_start = source.find('${chalk.bold("Options:")}')
    options_end = source.find("Extensions can register additional flags", options_start)
    if options_start < 0 or options_end < 0:
        fail("cannot find pi CLI options help block")

    rows: list[tuple[list[str], str | None, str]] = []
    for line in source[options_start:options_end].splitlines()[1:]:
        match = re.match(
            r"^\s{2}((?:--|-)[^ ]+(?:,\s+--?[^ ]+)?(?:\s+(?:<[^>]+>|\[[^]]+\]))?)\s{2,}(.+)$",
            line,
        )
        if match:
            syntax, help_text = match.groups()
            names = re.findall(r"-{1,2}[A-Za-z][A-Za-z0-9-]*", syntax)
            if not names:
                continue
            value_match = re.search(r"<([^>]+)>|\[([^]]+)\]", syntax)
            value_name = (value_match.group(1) or value_match.group(2)) if value_match else None
            rows.append((names, value_name, help_text.strip()))
        elif rows and re.match(r"^\s{20,}\S", line):
            names, value_name, help_text = rows[-1]
            rows[-1] = (names, value_name, f"{help_text} {line.strip()}")

    help_names = {name for names, _, _ in rows for name in names}
    if help_names != parsed_names:
        fail(
            "pi CLI parser/help census changed; "
            f"parser-only={sorted(parsed_names - help_names)!r}, help-only={sorted(help_names - parsed_names)!r}"
        )

    multiple_names = {
        "--append-system-prompt",
        "--extension",
        "--prompt-template",
        "--skill",
        "--theme",
    }
    flags: dict[str, dict[str, Any]] = {}
    for names, value_name, help_text in rows:
        primary = names[0]
        flags[primary] = {
            "help": help_text,
            "multiple": primary in multiple_names,
            "names": names,
            "optionalValue": primary == "--list-models",
            "origin": ["pi"],
            "valueName": value_name,
        }
    if "--approve" not in flags or "--no-approve" not in flags:
        fail("pi run-scoped trust flags disappeared")
    if len(flags) < 30:
        fail(f"pi CLI option census collapsed to {len(flags)} entries")
    return flags


def merge_flags(
    kimchi: dict[str, dict[str, Any]], pi: dict[str, dict[str, Any]]
) -> list[dict[str, Any]]:
    merged = {value["names"][0]: value for value in kimchi.values()}
    for primary, value in pi.items():
        if primary in merged:
            if "pi" not in merged[primary]["origin"]:
                merged[primary]["origin"].append("pi")
        else:
            merged[primary] = value
    return [merged[key] for key in sorted(merged)]


def extract_commands(kimchi_root: Path, pi_root: Path) -> dict[str, dict[str, Any]]:
    registry = read(kimchi_root / "src/commands/registry.ts")
    body = balanced_body(registry, "export const COMMANDS: CommandDefinition[] =", "[", "]")
    kimchi = {
        name: summary
        for name, summary in re.findall(
            r'\{\s*name:\s*"([^"]+)",\s*summary:\s*"([^"]+)"', body
        )
    }
    if len(kimchi) < 10:
        fail(f"Kimchi command census collapsed to {len(kimchi)} entries")

    package_cli = read(pi_root / "dist/package-manager-cli.js")
    pi_names = set(
        re.findall(r'rawCommand\s*===\s*"(install|remove|uninstall|update|list|config)"', package_cli)
    )
    pi_names.add("auth")
    if "const CONFIG_COMMAND_USAGE" in package_cli:
        pi_names.add("config")
    expected_pi = {"auth", "config", "install", "list", "remove", "uninstall", "update"}
    if pi_names != expected_pi:
        fail(f"pi command census changed: {sorted(pi_names)!r}")

    commands: dict[str, dict[str, Any]] = {
        "kimchi": {
            "implementations": [{"origin": "pi", "reachable": True}],
            "path": ["kimchi"],
        }
    }
    for name, summary in kimchi.items():
        commands[f"kimchi {name}"] = {
            "help": summary,
            "implementations": [{"origin": "kimchi", "reachable": True}],
            "path": ["kimchi", name],
        }
    for name in sorted(pi_names):
        key = f"kimchi {name}"
        implementation = {
            "origin": "pi",
            "reachable": name not in kimchi,
        }
        if name in kimchi:
            implementation["reason"] = "Kimchi's top-level dispatcher handles this command first"
        commands.setdefault(key, {"path": ["kimchi", name], "implementations": []})[
            "implementations"
        ].append(implementation)
    return dict(sorted(commands.items()))


def extract_cli(kimchi_root: Path, pi_root: Path) -> dict[str, Any]:
    kimchi_flags = extract_kimchi_cli_options(read(kimchi_root / "src/cli-args.ts"))
    pi_flags = extract_pi_flags(pi_root)
    return {
        "commands": extract_commands(kimchi_root, pi_root),
        "globalFlags": merge_flags(kimchi_flags, pi_flags),
    }


def production_sources(root: Path, suffix: str, excluded_parts: set[str]) -> list[Path]:
    return [
        path
        for path in root.rglob(f"*{suffix}")
        if not any(part in excluded_parts for part in path.parts)
        and ".test." not in path.name
        and not path.name.endswith(".map")
    ]


def discover_literal_env_reads(paths: list[Path]) -> set[str]:
    found: set[str] = set()
    pattern = re.compile(r"process\.env\.((?:KIMCHI|PI)_[A-Z0-9_]+)")
    for path in paths:
        source = read(path)
        for match in pattern.finditer(source):
            tail = source[match.end() : match.end() + 4]
            if re.match(r"\s*=($|[^=])", tail):
                continue
            found.add(match.group(1))
    return found


def extract_environment(kimchi_root: Path, pi_root: Path) -> dict[str, Any]:
    kimchi_paths = production_sources(kimchi_root / "src", ".ts", {"node_modules"})
    pi_paths = production_sources(pi_root / "dist", ".js", {"bundle"})
    discovered = discover_literal_env_reads(kimchi_paths + pi_paths)

    # These are read through named constants, generated names, bundled provider/TUI
    # code, or Kimchi's checked-in dependency patches rather than a literal
    # process.env.NAME access in the two primary source trees.
    indirect = {
        "KIMCHI_ACTIVE_FERMENT",
        "KIMCHI_DISABLE_BUILTIN_PROVIDERS",
        "KIMCHI_MCP_E2E_KEYRING_DIR",
        "KIMCHI_PARENT_SESSION_ID",
        "KIMCHI_PERMISSIONS",
        "KIMCHI_PROXY_HELPER",
        "KIMCHI_STREAM_IDLE_TIMEOUT_MS",
        "PI_CACHE_RETENTION",
        "PI_CODING_AGENT_SESSION_DIR",
        "PI_HYPERLINKS",
        "PI_IMAGE_PROTOCOL",
        "PI_OAUTH_CALLBACK_HOST",
        "PI_TRUE_COLOR",
        "PI_TUI_DEBUG",
        "PI_TUI_DEBUG_REDRAW",
        "PI_TUI_ESC_TIMEOUT",
        "PI_TUI_NO_CLEAR_SCROLLBACK",
        "PI_TUI_WRITE_LOG",
    }
    discovered.update(indirect)

    expected = set(ENVIRONMENT_METADATA)
    unknown = discovered - expected
    missing = expected - discovered
    if unknown or missing:
        fail(f"environment census changed; new={sorted(unknown)!r}, missing={sorted(missing)!r}")

    variables = {}
    for name, metadata in sorted(ENVIRONMENT_METADATA.items()):
        variables[name] = {
            "consumerOverridable": True,
            "readBy": sorted(
                runtime
                for runtime, paths in (("kimchi", kimchi_paths), ("pi", pi_paths))
                if any(name in read(path) for path in paths)
            )
            or (["kimchi"] if name.startswith("KIMCHI_") else ["pi"]),
            **metadata,
        }
    return {"variables": variables}


def extract(kimchi_root: Path, pi_root: Path, kimchi_version: str) -> dict[str, Any]:
    package = json.loads(read(pi_root / "package.json"))
    pi_version = package.get("version")
    if not isinstance(pi_version, str) or not pi_version:
        fail("pi package.json has no string version")
    kimchi_package = json.loads(read(kimchi_root / "package.json"))
    pinned_pi = kimchi_package.get("dependencies", {}).get("@earendil-works/pi-coding-agent")
    if pinned_pi != pi_version:
        fail(f"Kimchi pins pi {pinned_pi!r}, but the supplied pi source is {pi_version!r}")

    return {
        "cli": extract_cli(kimchi_root, pi_root),
        "config": extract_config(kimchi_root),
        "environment": extract_environment(kimchi_root, pi_root),
        "harness": extract_harness(kimchi_root, pi_root),
        "provenance": {
            "extractorSchema": EXTRACTOR_SCHEMA,
            "kimchiVersion": kimchi_version,
            "piVersion": pi_version,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kimchi-source", required=True, type=Path)
    parser.add_argument("--kimchi-version", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--pi-package", required=True, type=Path)
    args = parser.parse_args()

    result = extract(args.kimchi_source, args.pi_package, args.kimchi_version)
    encoded = json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if args.out == Path("-"):
        sys.stdout.write(encoded)
    else:
        args.out.write_text(encoded, encoding="utf-8")


if __name__ == "__main__":
    main()
