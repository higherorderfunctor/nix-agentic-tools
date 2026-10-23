# dev/tasks/codeql.nix — local CodeQL iteration. Explicit tasks only: none is
# wired before or after another, so no shell entry runs one.
{pkgs, ...}: let
  jq = "${pkgs.jq}/bin/jq";
in {
  tasks = {
    # The database the kimchi-codeql-database check builds, under
    # .devenv/state/codeql/kimchi, with the plain engine linked beside it, so
    # a query runs against it without Nix: packages/kimchi/docs/kimchi-codeql.md.
    # It rebuilds only when the Kimchi or CodeQL pin moves; delete `stamp` after
    # changing packages/kimchi/lib/codeql.nix (the source tree, the patch step
    # or the extractor environment) without a pin bump.
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
        create="$(nix build --no-link --print-out-paths "$codeql.createDatabase")"
        "$create/bin/kimchi-codeql-create-database" "$state"
        printf '%s\n' "$pins" > "$state/stamp"
      '';
    };
    "codeql:nix-db" = {
      description = "Create a CodeQL database of this repo's committed Nix source";
      exec = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        cd "$DEVENV_ROOT"
        state="''${DEVENV_STATE:?run this task from the devenv shell}/codeql/nix"
        system="$(nix eval --impure --raw --expr builtins.currentSystem)"
        codeql=".#ciPackages.$system.codeql-extractor-nix.passthru.codeql"
        engine="$(nix eval --raw "$codeql.engine.outPath")"
        create="$(nix eval --raw "$codeql.createDatabase.outPath")"
        stamp="$(git rev-parse HEAD) $engine $create"
        if [ -d "$state/db" ] && [ -f "$state/stamp" ] && [ "$(< "$state/stamp")" = "$stamp" ]; then
          echo "==> $state/db is current ($stamp)" >&2
          exit 0
        fi
        mkdir -p "$state"
        if [ -e "$state/stamp" ]; then rm "$state/stamp"; fi
        nix build --out-link "$state/engine" "$codeql.engine"
        nix build --no-link "$codeql.createDatabase"
        "$create/bin/nix-codeql-create-database" "$state"
        printf '%s\n' "$stamp" > "$state/stamp"
      '';
    };
  };
}
