# Runtime contract: nixpkgs' complete package must bootstrap the real daemon.
# Structure and helper stamps are checked before copying it to a fresh CODEX_HOME.
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

        # CLI and voice must carry the same source commit for their handshake.
        commit=${pkgs.lib.escapeShellArg codex.buildCommit}
        [ "$("$root/codex-resources/voice/bin/codex-voice-host" --build-commit)" = "$commit" ] \
          || fail "voice host does not report the source build commit $commit"
        grep -qaF "$commit" "$root/bin/codex" \
          || fail "bin/codex is not stamped with the voice build commit $commit"

        # nixpkgs' patches admit declared store links in daemon and voice loaders.
        for f in codex-path/rg ${pkgs.lib.optionalString isLinux "codex-resources/bwrap"}; do
          [ -L "$root/$f" ] && [ -e "$root/$f" ] || fail "invalid store link $f"
        done
        [ "$(find "$root" -name codex-package.json | wc -l)" -eq 1 ] \
          || fail "package must contain one layout"
        [ "$(find "$root" -name codex-voice-host | wc -l)" -eq 1 ] \
          || fail "package must contain one voice host"
        [ "$(find "$pkg/bin" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = "$(printf '%s\n' codex codex-code-mode-host)" ] \
          || fail "unexpected public executable set"

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

        echo "ok — Codex starts its daemon from ${codex}" > "$out"
      '';
    # Exercise the framed handshake and initialize GStreamer with discovery disabled.
    chatgpt-codex-voice-runtime = codex.passthru.tests.voice-runtime;
  };
}
