# dev/tasks/codeql.nix — local CodeQL iteration. Explicit tasks only: none is
# wired before or after another, so no shell entry runs one.
{pkgs, ...}: let
  jq = "${pkgs.jq}/bin/jq";
in {
  tasks = {
    # The database the kimchi-codeql-database check builds, under
    # .devenv/state/codeql/kimchi, with the plain engine linked beside it, so
    # a query runs against it without Nix: packages/kimchi/docs/kimchi-codeql.md.
    # It rebuilds only when the Kimchi or CodeQL pin moves; delete `stamp` to
    # force one.
    "codeql:kimchi-db" = {
      description = "Create the pinned Kimchi release's CodeQL database in .devenv/state/codeql/kimchi";
      exec = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        cd "$DEVENV_ROOT"
        state="''${DEVENV_STATE:?run this task from the devenv shell}/codeql/kimchi"
        pins="kimchi $(${jq} -er .version packages/kimchi/sources.json), codeql $(${jq} -er .version packages/codeql/sources.json)"
        if [ -d "$state/db" ] && [ -f "$state/stamp" ] && [ "$(< "$state/stamp")" = "$pins" ]; then
          echo "==> $state/db is current ($pins)" >&2
          exit 0
        fi
        system="$(nix eval --impure --raw --expr builtins.currentSystem)"
        codeql=".#ciPackages.$system.kimchi.passthru.codeql"
        mkdir -p "$state"
        rm -f "$state/stamp"
        echo "==> creating $state/db ($pins)" >&2
        nix build --out-link "$state/engine" "$codeql.engine"
        nix run "$codeql.createDatabase" -- "$state"
        printf '%s\n' "$pins" > "$state/stamp"
      '';
    };
  };
}
