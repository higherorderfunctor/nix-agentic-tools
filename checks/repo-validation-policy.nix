# Contract test for config/repo-validation.nix projections. This checks the
# rendered git-hooks configuration as well as the trunk guard's branch behavior.
{
  ciConfig,
  ciHookIds,
  definitionNames,
  formatterHookIds,
  judgmentHookIds,
  localConfig,
  pkgs,
  rejectEntry,
}:
pkgs.runCommandLocal "repo-validation-policy-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.diffutils pkgs.git pkgs.jq];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  # git-hooks.nix prefixes its JSON with two generated-file comments.
  tail -n +3 ${localConfig} > local.json
  tail -n +3 ${ciConfig} > ci.json

  {
    ${pkgs.lib.concatMapStringsSep "\n" (name: "echo ${pkgs.lib.escapeShellArg name}") definitionNames}
  } | sort > expected-local
  jq -r '.repos[].hooks[].id' local.json | sort > actual-local
  diff -u expected-local actual-local

  {
    ${pkgs.lib.concatMapStringsSep "\n" (name: "echo ${pkgs.lib.escapeShellArg name}") (formatterHookIds ++ judgmentHookIds)}
  } | sort > expected-manual
  jq -r '.repos[].hooks[] | select(.stages | index("manual")) | .id' local.json \
    | sort > actual-manual
  diff -u expected-manual actual-manual

  # A single treefmt process owns its SQLite cache. prek's default file-batch
  # fanout makes concurrent processes contend on that database, which turns
  # cache bootstrap into timeouts and can leave the hook effectively uncached.
  jq -e '
    [.repos[].hooks[] | select(.id == "treefmt")]
    | length == 1
      and .[0].require_serial
      and (.[0].entry | contains("--no-cache") | not)
  ' local.json >/dev/null

  {
    ${pkgs.lib.concatMapStringsSep "\n" (name: "echo ${pkgs.lib.escapeShellArg name}") ciHookIds}
  } | sort > expected-ci
  jq -r '.repos[].hooks[].id' ci.json | sort > actual-ci
  diff -u expected-ci actual-ci
  jq -e 'all(.repos[].hooks[]; .stages == ["manual"])' ci.json >/dev/null

  export HOME="$PWD/home"
  mkdir -p "$HOME" repo
  cd repo
  git init -q -b main
  git config user.email validation@example.invalid
  git config user.name validation
  echo base > README
  git add README
  git commit -qm base

  if ${rejectEntry} >/dev/null 2>&1; then
    echo "reject-default-branch-commit allowed main" >&2
    exit 1
  fi
  git switch -qc feature/policy-probe
  ${rejectEntry}
  git switch -q --detach
  ${rejectEntry}

  mkdir -p "$out"
  touch "$out/ok"
''
