#!/usr/bin/env bash
#
# Refuse every known way to author a Kiro v3 agent profile or hook document that
# LOADS WRONG WITHOUT SAYING SO.
#
# Every rule here exists because the engine's failure for that mistake is quiet.
# A profile with zero front-matter keys is dropped; a `.json` profile carrying a
# CLI-only field is skipped at debug level; a symlinked hook file is skipped with
# no log line at all; a matcher that does not compile makes a hook never fire, with only a
# load-time warning; `timeout: 0` is schema-valid and means NO TIMEOUT. None of
# these produce an error an operator would notice mid-session — they produce a
# probe that "did not fire", which is indistinguishable from a negative result.
# That is the whole reason to lint rather than to run and look.
#
# Exit codes are three-valued on purpose:
#
#   0  every examined file is clean
#   1  at least one finding
#   2  the linter could not run (missing tool, missing directory, nothing to
#      examine) — NOT a clean result, and never to be read as one
#
# Usage: lint-probes.sh [<agents-dir> <hooks-dir>]
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures_root="$(cd "$here/.." && pwd)"
awk_prog="$here/lint-agent-frontmatter.awk"

# The default agents dir is the INSTALLABLE subtree, not `agents/`. The loader
# keeps any entry ending `.md`, so a README sitting beside the profiles is itself
# a load candidate - which is how this layout got fixed: an earlier version kept
# the profiles and their README in one directory and this linter rejected the
# README as a profile with no front matter. It was right.
agents_dir="${1:-$fixtures_root/agents/profiles}"
hooks_dir="${2:-$fixtures_root/hooks}"

# The six ids in the engine's VALID_MODES. A custom profile taking one of these
# ids loads and is then filtered out of the mode registry, so it is not addressable
# while looking loaded.
builtin_mode_ids=(autonomous bug-fix plan quick-spec spec vibe)

# The 11 canonical trigger names. A hook whose trigger is not one of these is
# dropped at load.
canonical_triggers=(
  Manual
  PostFileCreate
  PostFileDelete
  PostFileSave
  PostTaskExec
  PostToolUse
  PreTaskExec
  PreToolUse
  SessionStart
  Stop
  UserPromptSubmit
)

# The two triggers that BYPASS the decision function and inject on any exit code,
# promoting stderr into the conversation whenever stdout is empty.
injecting_triggers=(SessionStart UserPromptSubmit)

# `.json` agent profiles only: these two fields make the loader skip the profile
# unless a KAS marker field (`permissions`) is also present and non-null.
cli_only_fields=(allowedTools toolsSettings)

findings=0
agents_examined=0
hooks_examined=0
matchers_seen=0
declare -a examined_agents=()
declare -a examined_hooks=()
declare -A effective_ids=()

die() {
  printf 'lint-probes: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'FAIL %s %s: %s\n' "$1" "$2" "$3"
  findings=$((findings + 1))
}

# Spelled with an explicit `if` rather than `[ … ] && return 0`: a failing
# `&&` list is a failing statement, and this function must stay safe to call
# outside a condition context under errexit.
in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# Strict JSON validity, judged by the same parser the engine uses.
#
# jq is NOT a substitute here and the difference is not academic: jq accepts a
# whitespace-separated STREAM of values, so `{"version":"v1"} {"version":"v1"}`
# passes jq and fails JSON.parse. Using jq as the gate would green-light a file
# the engine rejects. jq is still used below for querying, where its input has
# already been proven parseable.
json_parse_error() {
  node -e '
    const fs = require("fs");
    try {
      JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    } catch (err) {
      process.stdout.write(String(err.message));
      process.exit(1);
    }
  ' "$1"
}

# A matcher is compiled with the JavaScript RegExp constructor, so node is the
# only correct oracle for "does this compile".
regex_compile_error() {
  node -e '
    try {
      new RegExp(process.argv[1]);
    } catch (err) {
      process.stdout.write(String(err.message));
      process.exit(1);
    }
  ' "$1"
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

for tool in awk find jq node; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "missing required tool '${tool}' - refusing to run a partial check"
done
[ -f "$awk_prog" ] || die "missing front-matter checker at ${awk_prog}"
[ -d "$agents_dir" ] || die "no agents directory at ${agents_dir}"
[ -d "$hooks_dir" ] || die "no hooks directory at ${hooks_dir}"

# --------------------------------------------------------------------------
# Agent profiles: the loader walks the agents dir RECURSIVELY, keeps `.md` and
# `.json`, and FOLLOWS SYMLINKS. `find -L` mirrors all three.
# --------------------------------------------------------------------------

lint_agent_frontmatter() {
  local path="$1" rel="$2" kind field value
  while IFS=$'\t' read -r kind field value; do
    case "$kind" in
    finding) fail "$field" "$rel" "$value" ;;
    meta)
      case "$field" in
      name) fm_name="$value" ;;
      dispatchKind) fm_dispatch="$value" ;;
      *) ;;
      esac
      ;;
    *) ;;
    esac
  done < <(awk -f "$awk_prog" "$path")
}

lint_agent_json() {
  local path="$1" rel="$2" parse_msg field
  if ! parse_msg="$(json_parse_error "$path")"; then
    fail agent-json-invalid "$rel" "not valid JSON: ${parse_msg}"
    return 0
  fi

  # The loader's own test is `raw[field] != null`, so a null `permissions` does
  # not mark the profile. `jq -e` exits 1 when the result is false or null, which
  # is exactly the predicate wanted here.
  local marked=0
  if jq -e '.permissions != null' "$path" >/dev/null; then
    marked=1
  fi
  for field in "${cli_only_fields[@]}"; do
    if jq -e --arg f "$field" 'has($f)' "$path" >/dev/null &&
      [ "$marked" -eq 0 ]; then
      fail agent-json-cli-only-fields "$rel" \
        "carries the CLI-only field \`${field}\` with no non-null \`permissions\`, so the loader SILENTLY SKIPS this profile (debug log only)"
    fi
  done

  local hooks_type
  hooks_type="$(jq -r 'if has("hooks") then (.hooks | type) else "absent" end' "$path")"
  if [ "$hooks_type" != "absent" ] && [ "$hooks_type" != "array" ]; then
    fail agent-hooks-object-shaped "$rel" \
      "\`hooks\` is a JSON ${hooks_type}; v2's hooks is an OBJECT and v3's is an ARRAY, and the wrong shape drops the WHOLE profile"
  fi

  local bool_field bool_type
  for bool_field in includeMcpJson includePowers; do
    bool_type="$(jq -r --arg f "$bool_field" 'if has($f) then (.[$f] | type) else "absent" end' "$path")"
    if [ "$bool_type" != "absent" ] && [ "$bool_type" != "boolean" ]; then
      fail agent-strict-boolean "$rel" \
        "\`${bool_field}\` is boolean-typed but holds a ${bool_type}, so the profile fails validation and is dropped"
    fi
  done

  fm_dispatch="$(jq -r '.dispatchKind // ""' "$path")"
  fm_name="$(jq -r '.name // ""' "$path")"
}

mapfile -d '' agent_files < <(
  find -L "$agents_dir" -type f \( -name '*.md' -o -name '*.json' \) -print0 |
    LC_ALL=C sort -z
)

# With -L a working symlink is typed as its target, so anything still typed as a
# link is BROKEN. The engine logs "Skipping broken symlink" and moves on.
mapfile -d '' agent_broken_links < <(find -L "$agents_dir" -type l -print0 | LC_ALL=C sort -z)
for path in ${agent_broken_links[@]+"${agent_broken_links[@]}"}; do
  fail agent-broken-symlink "${path#"$agents_dir"/}" \
    "dangling symlink; the loader warns and skips it, so the profile is absent"
done

for path in ${agent_files[@]+"${agent_files[@]}"}; do
  rel="${path#"$agents_dir"/}"
  agent_id="${rel%.md}"
  agent_id="${agent_id%.json}"
  fm_name=""
  fm_dispatch=""

  # A documentation file is not exempt from being loaded. The walker keeps ANY
  # `.md`, so a README beside the profiles is parsed as one and throws. Naming
  # the real cause beats reporting "no front matter" on a file that was never
  # meant to have any.
  case "$(printf '%s' "${rel##*/}" | tr '[:upper:]' '[:lower:]')" in
  readme.md | readme.json)
    fail agent-doc-file-in-agents-dir "$rel" \
      "the loader keeps ANY .md or .json entry, so a documentation file here is parsed as a profile and throws; keep docs outside the installable tree"
    ;;
  esac

  case "$path" in
  *.md) lint_agent_frontmatter "$path" "$rel" ;;
  *.json) lint_agent_json "$path" "$rel" ;;
  esac

  # `effectiveId = frontMatter.name ?? agentId`, so an explicit `name` overrides
  # the path-derived id and can collide where the filename does not.
  effective_id="$agent_id"
  [ -n "$fm_name" ] && effective_id="$fm_name"

  if in_list "$agent_id" "${builtin_mode_ids[@]}"; then
    fail agent-builtin-id-collision "$rel" \
      "the path-derived id \`${agent_id}\` is a builtin mode id; such a profile LOADS and is then filtered out of the registry, so it is not addressable while looking loaded - prefix it"
  fi
  if [ "$effective_id" != "$agent_id" ] && in_list "$effective_id" "${builtin_mode_ids[@]}"; then
    fail agent-builtin-id-collision "$rel" \
      "\`name: ${effective_id}\` overrides the filename with a builtin mode id; the profile loads and is then filtered out of the registry - prefix it"
  fi

  if [ -n "${effective_ids["$effective_id"]:-}" ]; then
    fail agent-duplicate-effective-id "$rel" \
      "resolves to the same effective id \`${effective_id}\` as ${effective_ids["$effective_id"]}; one silently shadows the other"
  else
    effective_ids["$effective_id"]="$rel"
  fi

  if [ -n "$fm_dispatch" ] &&
    ! in_list "$fm_dispatch" custom-agent spec sub-agent; then
    fail agent-dispatch-kind-invalid "$rel" \
      "\`dispatchKind: ${fm_dispatch}\` is outside the enum (custom-agent, spec, sub-agent); an out-of-enum value fails validation and drops the profile"
  fi

  examined_agents+=("$rel")
  agents_examined=$((agents_examined + 1))
done

# --------------------------------------------------------------------------
# Hook documents: the per-root scan is FLAT and keeps only plain files.
# --------------------------------------------------------------------------

lint_hook_entry() {
  local rel="$1" hook="$2" index="$3"
  local name trigger action_type payload cmd

  name="$(jq -r 'if (.name | type) == "string" then .name else "" end' <<<"$hook")"
  trigger="$(jq -r 'if (.trigger | type) == "string" then .trigger else "" end' <<<"$hook")"
  action_type="$(jq -r 'if (.action | type) == "object" then (.action.type // "") else "" end' <<<"$hook")"

  [ -n "$name" ] ||
    fail hook-schema-invalid "$rel" "hooks[${index}] has no non-empty string \`name\`, which is required"
  if [ -z "$trigger" ]; then
    fail hook-schema-invalid "$rel" "hooks[${index}] has no non-empty string \`trigger\`, which is required"
  elif ! in_list "$trigger" "${canonical_triggers[@]}"; then
    fail hook-schema-invalid "$rel" \
      "hooks[${index}] trigger \`${trigger}\` is not one of the 11 canonical names, so the hook is dropped at load"
  fi

  case "$action_type" in
  agent)
    payload="$(jq -r 'if (.action.prompt | type) == "string" then .action.prompt else "" end' <<<"$hook")"
    [ -n "$payload" ] ||
      fail hook-schema-invalid "$rel" "hooks[${index}] is an agent action with no non-empty \`prompt\`"
    ;;
  command)
    cmd="$(jq -r 'if (.action.command | type) == "string" then .action.command else "" end' <<<"$hook")"
    if [ -z "$cmd" ]; then
      fail hook-schema-invalid "$rel" "hooks[${index}] is a command action with no non-empty \`command\`"
    else
      lint_hook_command "$rel" "$index" "$trigger" "$cmd"
    fi
    ;;
  *)
    fail hook-schema-invalid "$rel" \
      "hooks[${index}] action type \`${action_type}\` is neither \`command\` nor \`agent\`"
    ;;
  esac

  if jq -e '.timeout == 0' <<<"$hook" >/dev/null; then
    fail hook-timeout-zero "$rel" \
      "hooks[${index}] sets \`timeout: 0\`, which is schema-VALID and means NO TIMEOUT AT ALL - it is not 'use the default', which is 60"
  fi

  if jq -e 'has("matcher")' <<<"$hook" >/dev/null; then
    matchers_seen=$((matchers_seen + 1))
    local pattern compile_msg
    pattern="$(jq -r '.matcher' <<<"$hook")"
    if ! compile_msg="$(regex_compile_error "$pattern")"; then
      fail hook-matcher-invalid "$rel" \
        "hooks[${index}] matcher does not compile (${compile_msg}); the hook then NEVER FIRES, with only a load-time warning"
    fi
    fail hook-matcher-present "$rel" \
      "hooks[${index}] sets a matcher; probes must omit it (absent means match-all). It is ignored for 6 of the 11 triggers and unanchored for the rest, so \`read\` also matches \`read_files\`"
  fi
}

lint_hook_command() {
  local rel="$1" index="$2" trigger="$3" cmd="$4"
  local -a refs=()
  mapfile -t refs < <(printf '%s\n' "$cmd" | grep -oE '[A-Za-z0-9._-]+\.sh' || true)

  if [ "${#refs[@]}" -ne 1 ]; then
    fail hook-script-unresolved "$rel" \
      "hooks[${index}] command names ${#refs[@]} \`*.sh\` files; every probe must reference exactly one script under the hooks dir's bin/ so this linter can check it"
    return 0
  fi

  local script="$hooks_dir/bin/${refs[0]}"
  if [ ! -f "$script" ]; then
    fail hook-script-missing "$rel" \
      "hooks[${index}] references \`${refs[0]}\`, which is not a regular file at ${script}; a hook pointing at nothing fails silently"
    return 0
  fi
  if [ ! -x "$script" ]; then
    fail hook-script-missing "$rel" \
      "hooks[${index}] references \`${refs[0]}\`, which is not executable"
  fi
  if in_list "$trigger" "${injecting_triggers[@]}" && grep -q '>&2' "$script"; then
    fail hook-stderr-in-injecting-probe "$rel" \
      "hooks[${index}] is a ${trigger} hook whose script writes to stderr; an empty stdout promotes stderr into the conversation, so progress output becomes model-visible text"
  fi
}

# A `.json` below the top level is NEVER SEEN by the per-root scan. This is the
# exact opposite of the agents loader, which recurses.
mapfile -d '' nested_hook_json < <(
  find "$hooks_dir" -mindepth 2 -name '*.json' -print0 | LC_ALL=C sort -z
)
for path in ${nested_hook_json[@]+"${nested_hook_json[@]}"}; do
  fail hook-nested-json "${path#"$hooks_dir"/}" \
    "the per-root hook scan is FLAT (<root>/.kiro/hooks/*.json); a .json in a subdirectory is never read"
done

mapfile -d '' hook_files < <(
  find "$hooks_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.json' -print0 |
    LC_ALL=C sort -z
)

for path in ${hook_files[@]+"${hook_files[@]}"}; do
  rel="${path#"$hooks_dir"/}"
  examined_hooks+=("$rel")
  hooks_examined=$((hooks_examined + 1))

  # The directory reader types a symlink as its own kind and the loader keeps
  # only plain files, so this file is invisible - no warning, no log line.
  if [ -L "$path" ]; then
    fail hook-symlink "$rel" \
      "hook files must be REAL REGULAR FILES; a symlinked hook is SILENTLY skipped, which is exactly what declarative store-symlink delivery produces"
  fi

  if ! parse_msg="$(json_parse_error "$path")"; then
    fail hook-json-invalid "$rel" "not valid JSON: ${parse_msg}"
    # Name the two shapes that a JSON5-shaped edit produces. Hook files are read
    # with a PLAIN JSON parser, unlike agent JSON which tolerates comments.
    if grep -qE '(^|[[:space:]])//|/\*' "$path"; then
      fail hook-json-comment "$rel" \
        "contains a comment; hook documents are read with a plain JSON parser and comments are a parse error"
    fi
    # `tr` first, because a trailing comma is USUALLY the last thing on its line
    # and the closing brace is on the NEXT one. A line-oriented grep cannot see
    # across that newline, and the first version of this check silently reported
    # only the generic parse error for the commonest spelling of the defect.
    if tr '\n' ' ' <"$path" | grep -qE ',[[:space:]]*[]}]'; then
      fail hook-json-trailing-comma "$rel" \
        "contains a trailing comma; hook documents are read with a plain JSON parser"
    fi
    continue
  fi

  version="$(jq -r '.version // ""' "$path")"
  [ "$version" = "v1" ] ||
    fail hook-schema-invalid "$rel" "\`version\` must be the literal \"v1\", found \"${version}\""

  hooks_type="$(jq -r 'if has("hooks") then (.hooks | type) else "absent" end' "$path")"
  if [ "$hooks_type" != "array" ]; then
    fail hook-schema-invalid "$rel" "\`hooks\` must be an array, found ${hooks_type}"
    continue
  fi
  hooks_len="$(jq -r '.hooks | length' "$path")"
  if [ "$hooks_len" -eq 0 ]; then
    # No backticks in this message: it interpolates nothing, so shfmt rewrites
    # it to a single-quoted string, and a backtick inside single quotes then
    # trips SC2016 in the linter that gates this repo's commits.
    fail hook-schema-invalid "$rel" 'the hooks array must have at least one entry'
    continue
  fi

  index=0
  while IFS= read -r hook_json; do
    lint_hook_entry "$rel" "$hook_json" "$index"
    index=$((index + 1))
  done < <(jq -c '.hooks[]' "$path")
done

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

printf 'agent profiles examined: %d\n' "$agents_examined"
for rel in ${examined_agents[@]+"${examined_agents[@]}"}; do
  printf '  %s\n' "$rel"
done
printf 'hook documents examined: %d\n' "$hooks_examined"
for rel in ${examined_hooks[@]+"${examined_hooks[@]}"}; do
  printf '  %s\n' "$rel"
done
printf 'matcher fields seen:     %d\n' "$matchers_seen"
printf 'findings:                %d\n' "$findings"

# A denominator of zero is not a pass. "Everything is clean" is vacuous when
# nothing was read, and that is exactly how a mistyped directory presents.
if [ "$((agents_examined + hooks_examined))" -eq 0 ]; then
  die "examined nothing - ${agents_dir} and ${hooks_dir} hold no profiles or hook documents"
fi

if [ "$findings" -ne 0 ]; then
  printf 'FAILED with %d finding(s)\n' "$findings"
  exit 1
fi
echo 'PASS'
