# Materialize a KAS engine bundle with selected exact-match prompt patches.
#
# ── Why this is a LAUNCH-time materializer and not a derivation ──────────────
# The engine bundle is NOT in the nix store. `kiro-cli` carries it as an
# embedded asset and unpacks it on first use into
# `$KIRO_DATA_DIR/kas/<version>-<sha256>/`, so at build time there is nothing to
# patch directly. A dummy KIRO_API_KEY with `acp --agent-engine v3` does unpack
# a bundle without credentials or network in a sandbox (the bundle drift
# check uses this). Prompt replacement stays at launch so it patches the
# user's actual engine bundle, including after CLI upgrades.
#
# So the patch is applied where the bundle actually exists: on the user's
# machine, at launch, into a cache keyed by the engine bundle, selected
# replacements and patcher source. A CLI upgrade, edited option or patcher
# change must not be served a stale patch.
#
# ── Why `KIRO_KAS_SERVER_PATH` rather than editing the vendor tree ───────────
# The chat binary passes that variable to node as the entry module, with no hash
# check of any kind -- the `.sha256` sidecars and the "existing hash is
# different from embedded hash" logic guard only the EXTRACTION step, which this
# bypasses. Editing the extracted tree in place would work too, and is what the
# vendor's own re-extraction would silently undo on the next upgrade. Pointing
# at a copy leaves vendor state untouched.
#
# The bundle resolves 54 sibling packages (z3-solver and friends) out of its own
# `node_modules`, so the copy cannot be a lone file: it mirrors the vendor
# layout with symlinks and substitutes exactly one real file. Node walks up from
# the entry file's directory looking for `node_modules`, which is why the
# mirrored depth has to match rather than merely being "somewhere writable".
{
  lib,
  pkgs,
}: let
  patcher = ./kiro-bundle-patch.py;
in
  # Both backends select the same `ai.kiro.cli.tweaks`; every tweak defaults off.
  # `replace` names the enabled fixed-text tweaks (the patcher's `FIXED` keys).
  {
    cliVersion,
    identity ? null,
    replace ? [],
  }: let
    patchKey = builtins.hashString "sha256" (builtins.toJSON {
      inherit identity replace;
      source = builtins.readFile patcher;
    });
    replacementNames = lib.concatStringsSep ", " (lib.optional (identity != null) "identity" ++ replace);
  in
    pkgs.writeShellApplication {
      name = "kiro-bundle-materialize";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      runtimeInputs = [];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :

        # Absolute store paths throughout: this runs from a launcher wrapper that
        # may be spawned with a replaced or empty PATH (nix-standards).
        coreutils=${lib.escapeShellArg pkgs.coreutils}
        python=${lib.escapeShellArg (lib.getExe pkgs.python3)}
        patcher=${lib.escapeShellArg patcher}

        data_dir="''${KIRO_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli}"
        cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}/nix-agentic-tools/kiro-bundle"

        # Resolve the engine bundle deterministically, never by glob order.
        # Several bundles accumulate side by side (seven, on the machine this
        # was developed against), and lexical-FIRST selects one many releases
        # behind while lexical-last and newest-by-mtime merely happen to be
        # right today -- so a wrong resolver looks like it works.
        #
        # Exact-version match is NOT sufficient either: the embedded engine may
        # LAG the CLI (a 2.15.2 CLI shipped a 2.15.1 KAS), so an exact glob
        # legitimately finds nothing. The rule is therefore "highest bundle
        # version that does not exceed the CLI version", computed with a real
        # version comparison rather than `sort -V`, which is a GNU extension
        # this repo cannot assume on darwin.
        kas="$("$python" -c '
        import os, sys
        root, cli = sys.argv[1], sys.argv[2]
        def key(v):
            return tuple(int(p) if p.isdigit() else -1 for p in v.split("."))
        try:
            names = os.listdir(root)
        except OSError:
            sys.exit(1)
        candidates = []
        for n in names:
            p = os.path.join(root, n)
            if not os.path.isdir(p) or "-" not in n:
                continue
            ver = n.split("-", 1)[0]
            if key(ver) <= key(cli):
                candidates.append((key(ver), p))
        if not candidates:
            sys.exit(1)
        sys.stdout.write(max(candidates)[1] + "/")
        ' "$data_dir/kas" ${lib.escapeShellArg cliVersion} 2>/dev/null)" || {
          echo "WARNING: kiro-bundle-patch (${replacementNames}): no engine bundle at or below CLI version ${cliVersion} under $data_dir/kas; launching unpatched (the engine unpacks on first use, so this resolves itself after one run)" >&2
          exit 1
        }
        src="''${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
        [ -f "$src" ] || { echo "WARNING: kiro-bundle-patch (${replacementNames}): no acp-server.js under $kas; launching unpatched" >&2; exit 1; }

        key="$("$coreutils"/bin/basename "''${kas%/}")-${patchKey}"
        out="$cache_root/$key"
        server="$out/node_modules/@kiro/agent/dist/server/acp-server.js"

        # Keep the per-key lock outside `out`: rebuilding deletes that directory.
        # Recheck readiness only after acquiring it, so a waiting launch cannot
        # delete a bundle another launch has already published and returned.
        "$coreutils"/bin/mkdir -p "$cache_root"
        exec 9>"$cache_root/$key.lock"
        ${lib.getExe pkgs.flock} 9

        # `.ready` is written last, so an interrupted materialization is retried
        # rather than served half-built. A ready bundle may still have skipped a
        # drifted replacement; replay its warnings so every launch names it.
        # `-s` refuses an absent or empty `.skipped`: nothing was skipped.
        if [ -f "$out/.ready" ]; then
          if [ -s "$out/.skipped" ]; then "$coreutils"/bin/cat "$out/.skipped" >&2; fi
          printf %s "$server"
          exit 0
        fi

        if [ -e "$out" ]; then "$coreutils"/bin/rm -r "$out"; fi
        "$coreutils"/bin/mkdir -p "$out/node_modules/@kiro/agent/dist/server"

        link_all() { # srcdir dest skip
          local e n
          for e in "$1"/*; do
            n="$("$coreutils"/bin/basename "$e")"
            [ "$n" = "$3" ] && continue
            "$coreutils"/bin/ln -s "$e" "$2/$n"
          done
        }
        nm="''${kas}node_modules"
        link_all "$nm"                          "$out/node_modules"                         "@kiro"
        link_all "$nm/@kiro"                    "$out/node_modules/@kiro"                   "agent"
        link_all "$nm/@kiro/agent"              "$out/node_modules/@kiro/agent"             "dist"
        link_all "$nm/@kiro/agent/dist"         "$out/node_modules/@kiro/agent/dist"        "server"
        link_all "$nm/@kiro/agent/dist/server"  "$out/node_modules/@kiro/agent/dist/server" "acp-server.js"

        # Publish when at least one replacement applies, keeping the patcher's
        # skip warnings for later launches. If all selected sources drift, the
        # wrapper handles the failure and starts Kiro with stock.
        status=0
        "$python" "$patcher" "$src" "$server" \
          ${lib.optionalString (identity != null) "--identity-file ${lib.escapeShellArg (pkgs.writeText "kiro-identity.txt" identity)}"} \
          ${lib.concatMapStringsSep " " (name: "--replace ${lib.escapeShellArg name}") replace} \
          2>"$out/.skipped" || status=$?
        if [ -s "$out/.skipped" ]; then "$coreutils"/bin/cat "$out/.skipped" >&2; fi
        [ "$status" -eq 0 ] || exit 1
        "$coreutils"/bin/touch "$out/.ready"
        printf %s "$server"
      '';
    }
