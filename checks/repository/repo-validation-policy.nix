# Contract test for config/repo-validation.nix projections. This checks the
# rendered git-hooks configuration as well as the trunk guard's branch behavior.
{
  ciConfig,
  localConfig,
  pkgs,
  rejectEntry,
  ...
}:
pkgs.runCommandLocal "repo-validation-policy-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.diffutils pkgs.git pkgs.gnugrep pkgs.jq];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  # git-hooks.nix prefixes its JSON with two generated-file comments.
  tail -n +3 ${localConfig} > local.json
  tail -n +3 ${ciConfig} > ci.json

  assert_hook_ids() {
    local config="$1" selection="$2"
    shift 2
    printf '%s\n' "$@" | LC_ALL=C sort > expected-ids
    jq -r ".repos[].hooks[] | $selection | .id" "$config" | LC_ALL=C sort > actual-ids
    diff -u --label "expected $config ($selection)" --label "actual $config ($selection)" \
      expected-ids actual-ids
  }

  # Pin the rendered membership independently of the policy's projections:
  # a misclassified or missing hook must not change both the inputs and the oracle.
  assert_hook_ids local.json . \
    convco cspell deadnix gitleaks markdown-table-cells reject-default-branch-commit \
    shellcheck statix treefmt treefmt-restage unique-map-keys
  assert_hook_ids local.json 'select(.stages | index("manual"))' \
    cspell deadnix markdown-table-cells shellcheck statix treefmt unique-map-keys

  # A single treefmt process owns its SQLite cache. prek's default file-batch
  # fanout makes concurrent processes contend on that database, which turns
  # cache bootstrap into timeouts and can leave the hook effectively uncached.
  jq -e '
    [.repos[].hooks[] | select(.id == "treefmt")]
    | length == 1
      and .[0].require_serial
      and (.[0].entry | contains("--no-cache") | not)
  ' local.json >/dev/null

  assert_hook_ids ci.json . cspell deadnix markdown-table-cells statix unique-map-keys
  jq -e 'all(.repos[].hooks[]; .stages == ["manual"])' ci.json >/dev/null

  # Local and CI cspell invocations must tolerate batches filtered entirely by
  # ignorePaths while retaining filename passing and parallel execution.
  for config in local.json ci.json; do
    jq -e '
      [.repos[].hooks[] | select(.id == "cspell")]
      | length == 1
        and (.[0].args | index("--no-must-find-files") != null)
        and .[0].pass_filenames == true
        and .[0].require_serial == false
    ' "$config" >/dev/null
  done

  export HOME="$PWD/home"
  mkdir -p "$HOME" repo
  cd repo
  git init -q -b main
  git config user.email validation@example.invalid
  git config user.name validation
  echo base > README
  git add README
  git commit -qm base

  status=0
  ${rejectEntry} > /dev/null 2> guard.err || status=$?
  if [ "$status" -ne 1 ] || ! grep -Fxq "error: refusing to commit directly on the default branch ('main')." guard.err; then
    echo "reject-default-branch-commit: expected a trunk refusal on main, got exit $status" >&2
    cat guard.err >&2
    exit 1
  fi
  git switch -qc feature/policy-probe
  ${rejectEntry}
  git switch -q --detach
  ${rejectEntry}

  mkdir -p "$out"
  touch "$out/ok"
''
