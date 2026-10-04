# Runtime contract — Codex must recognize its own install as a complete
# package, and start its background daemon from it.
#
# Since 0.157.0 an interactive `codex` launch auto-starts the app-server
# daemon, and the daemon bootstrap refuses to run unless the CLI's canonical
# executable sits at `<root>/bin/codex` beside `<root>/codex-package.json`.
# 0.157.1 shipped here from the loose release binaries, with no manifest, and
# every launch died with "this CLI has no complete local package". Nothing
# failed at build time: `codex --version` does not consult the package.
#
# So this check runs the bootstrap itself, `codex app-server daemon start`,
# against a throwaway CODEX_HOME, then stops it. That is the exact code path
# (codex-rs/app-server-daemon, prepare_install.rs) that failed. It needs no
# network and no credentials: the daemon copies the package and answers on a
# local socket. The structural assertions before it name the broken piece
# rather than leaving the reader a daemon error to decode.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) isLinux system;
    codex = self.ciPackages.${system}.chatgpt-codex;
    inherit (codex.passthru.codexPackage) resources root target;
    # The files the daemon bootstrap's `validate_package` requires, each
    # executable. bwrap is Linux-only upstream too.
    required =
      ["bin/codex" "bin/codex-code-mode-host" "codex-path/rg"]
      ++ pkgs.lib.optional isLinux "codex-resources/bwrap";
  in {
    chatgpt-codex-package-layout =
      pkgs.runCommand "chatgpt-codex-package-layout" {
        nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.jq pkgs.procps];
      } ''
        fail() {
          echo "FAIL: $*" >&2
          exit 1
        }

        pkg=${codex}
        root="$(realpath "$pkg/${root}")"

        # Codex locates its package from its canonical executable, so resolve
        # the entrypoint exactly as exec does.
        [ "$(realpath "$pkg/bin/codex")" = "$root/bin/codex" ] \
          || fail "bin/codex resolves to $(realpath "$pkg/bin/codex"), not $root/bin/codex"
        [ "$(realpath "$pkg/bin/codex-code-mode-host")" = "$root/bin/codex-code-mode-host" ] \
          || fail "bin/codex-code-mode-host does not resolve into the package"

        [ -f "$root/codex-package.json" ] || fail "$root has no codex-package.json"
        jq -e --arg version ${codex.version} --arg target ${target} \
          '.version == $version and .target == $target and .entrypoint == "bin/codex"' \
          "$root/codex-package.json" > /dev/null \
          || fail "codex-package.json does not describe this package: $(cat "$root/codex-package.json")"

        for f in ${pkgs.lib.escapeShellArgs (required ++ resources)}; do
          [ -f "$root/$f" ] && [ -x "$root/$f" ] || fail "package is missing executable $f"
        done

        # The prebuilt zsh is the one resource that runs on its own; on Linux
        # this proves its interpreter and libtinfo were repointed at nix.
        [ "$("$root/codex-resources/zsh/bin/zsh" -fc 'print ok')" = ok ] \
          || fail "bundled zsh does not run"

        # The bootstrap copies the tree and rejects links that leave it.
        links="$(find "$root" -type l)"
        [ -z "$links" ] || fail "package contains symlinks: $links"

        # The behavioral half: the bootstrap that failed. A short CODEX_HOME
        # keeps the control socket under the Unix path-length limit.
        export HOME="$TMPDIR/home"
        export CODEX_HOME="$TMPDIR/c"
        mkdir -p "$HOME" "$CODEX_HOME"
        timeout 120 "$pkg/bin/codex" app-server daemon start < /dev/null > start.json \
          || fail "daemon start failed"
        jq -e --arg version ${codex.version} \
          '.status == "started" and .managedCodexVersion == $version' start.json > /dev/null \
          || fail "daemon did not start from this package: $(cat start.json)"
        timeout 120 "$pkg/bin/codex" app-server daemon stop < /dev/null > stop.json \
          || fail "daemon stop failed"
        # `stop` leaves the managed updater loop behind; it must not outlive
        # the build.
        pkill -f "$CODEX_HOME" || :

        echo "ok — Codex starts its daemon from ${codex}" > $out
      '';
  };
}
