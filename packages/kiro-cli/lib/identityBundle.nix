# Materialize a KAS engine bundle whose kiro-cli identity sentence is replaced.
#
# ── Why this is a LAUNCH-time materializer and not a derivation ──────────────
# The engine bundle is NOT in the nix store. `kiro-cli` carries it as an
# embedded asset and unpacks it on first use into
# `$KIRO_DATA_DIR/kas/<version>-<sha256>/`, so at build time there is nothing to
# patch. Extraction cannot be moved into a derivation either: the binary checks
# authentication BEFORE it unpacks, so a sandbox with no credentials and no
# network never produces a bundle (measured -- `error: You are not logged in`,
# then a bare `os error 2` once an API key is present). Anything that got past
# those gates would be relying on undocumented behavior of a proprietary binary
# inside CI, which is a worse drift risk than the one this option exists to
# avoid.
#
# So the patch is applied where the bundle actually exists: on the user's
# machine, at launch, into a cache keyed by (engine bundle, replacement text).
# Both halves of that key matter -- a CLI upgrade ships a new bundle, and an
# edited option must not be served a stale patch.
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
  splicer = ./kiro-identity-splice.py;
in
  # `identity` is the replacement sentence; `cliVersion` is the kiro-cli
  # package version, used to pick the right engine bundle. Returns a package
  # exposing `bin/kiro-identity-materialize`, which prints the patched server
  # path on stdout and materializes it on first use.
  {
    identity,
    cliVersion,
  }:
    pkgs.writeShellApplication {
      name = "kiro-identity-materialize";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      runtimeInputs = [];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :

        # Absolute store paths throughout: this runs from a launcher wrapper that
        # may be spawned with a replaced or empty PATH (nix-standards).
        coreutils=${lib.escapeShellArg pkgs.coreutils}
        python=${lib.escapeShellArg (lib.getExe pkgs.python3)}
        splice=${lib.escapeShellArg splicer}

        data_dir="''${KIRO_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli}"
        cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}/nix-agentic-tools/kiro-identity"

        # The replacement is written to a file rather than passed as argv so the
        # sentence can contain anything the JS literal tolerates, and so the
        # cache key is a hash of the exact bytes that will be spliced.
        repl_file="$(mktemp "''${TMPDIR:-/tmp}/kiro-identity.XXXXXX")"
        trap '"'"'rm -f "$repl_file"'"'"' EXIT
        printf %s ${lib.escapeShellArg identity} > "$repl_file"

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
          echo "kiro-identity: no engine bundle at or below CLI version ${cliVersion} under $data_dir/kas; launching unpatched (the engine unpacks on first use, so this resolves itself after one run)" >&2
          exit 1
        }
        src="''${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
        [ -f "$src" ] || { echo "kiro-identity: no acp-server.js under $kas; launching unpatched" >&2; exit 1; }

        key="$("$coreutils"/bin/basename "''${kas%/}")-$("$coreutils"/bin/sha256sum "$repl_file" | "$coreutils"/bin/cut -c1-16)"
        out="$cache_root/$key"
        server="$out/node_modules/@kiro/agent/dist/server/acp-server.js"

        # `.ready` is written last, so an interrupted materialization is retried
        # rather than served half-built.
        if [ -f "$out/.ready" ]; then
          printf %s "$server"
          exit 0
        fi

        "$coreutils"/bin/rm -rf "$out"
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

        # Record what is being replaced, so the vendor sentence is readable
        # without re-deriving it from a 20 MB bundle. This is the honest form of
        # a "sidecar": it is produced where the bundle actually exists, and so
        # it can never describe a version other than the installed one.
        "$python" "$splice" "$src" --print > "$out/vendor-sentence.txt"
        "$coreutils"/bin/cp "$repl_file" "$out/replacement-sentence.txt"

        "$python" "$splice" "$src" "$server" "$repl_file"
        "$coreutils"/bin/touch "$out/.ready"
        printf %s "$server"
      '';
    }
