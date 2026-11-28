# Runtime contract: nixpkgs' complete package must bootstrap the real daemon.
# Structure and helper stamps are checked before copying it to a fresh CODEX_HOME.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    codex = self.ciPackages.${system}.chatgpt-codex;
    inherit (codex.passthru.codexPackage) resources root target;
    publicExecutables = ["codex" "codex-code-mode-host"];
  in {
    chatgpt-codex-package-layout =
      pkgs.runCommand "chatgpt-codex-package-layout" {
        nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.jq pkgs.procps];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "FAIL: $*" >&2
          exit 1
        }

        pkg=${codex}
        root="$(realpath "$pkg/${root}")"

        # Codex locates its package from its canonical executable, so resolve
        # the entrypoint exactly as exec does.
        for exe in ${pkgs.lib.escapeShellArgs publicExecutables}; do
          actual="$(realpath "$pkg/bin/$exe")"
          [ "$actual" = "$root/bin/$exe" ] \
            || fail "bin/$exe resolves to $actual, not $root/bin/$exe"
        done

        jq -e --arg version ${codex.version} --arg target ${target} \
          '.version == $version and .target == $target and .entrypoint == "bin/codex"' \
          "$root/codex-package.json" > /dev/null \
          || fail "codex-package.json does not describe this package: $(cat "$root/codex-package.json")"

        for f in ${pkgs.lib.escapeShellArgs resources}; do
          [ -f "$root/$f" ] && [ -x "$root/$f" ] || fail "package is missing executable $f"
        done

        # The CLI must carry the source commit used by the voice handshake.
        commit=${pkgs.lib.escapeShellArg codex.buildCommit}
        grep -qaF "$commit" "$root/bin/codex" \
          || fail "bin/codex is not stamped with the voice build commit $commit"

        [ "$(find "$root" -name codex-package.json | wc -l)" -eq 1 ] \
          || fail "package must contain one layout"
        [ "$(find "$root" -name codex-voice-host | wc -l)" -eq 1 ] \
          || fail "package must contain one voice host"
        [ "$(find "$pkg/bin" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = "$(printf '%s\n' ${pkgs.lib.escapeShellArgs publicExecutables})" ] \
          || fail "unexpected public executable set"

        # Bootstrap validates the daemon's executable helpers, including
        # bwrap on Linux. A short CODEX_HOME keeps the control socket under
        # the Unix path-length limit.
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

        echo "ok — Codex starts its daemon from ${codex}" > "$out"
      '';
    # Exercise the framed handshake and initialize GStreamer with discovery disabled.
    chatgpt-codex-voice-runtime = codex.passthru.tests.voice-runtime;
  };
}
