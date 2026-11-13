{
  gum,
  lib,
  libnotify,
  python3,
  stdenvNoCC,
  writeShellScript,
  xdg-utils,
}: let
  # macOS has no notify-send or xdg-open; its built-ins take the same
  # arguments the daemon and login pass: a title and a message, or a URL.
  # The message travels as an osascript argument, never as script text.
  darwinNotifier = writeShellScript "mcp-oauth-notify" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    exec /usr/bin/osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$1" "$2"
  '';
  notifier =
    if stdenvNoCC.hostPlatform.isDarwin
    then darwinNotifier
    else "${libnotify}/bin/notify-send";
  browser =
    if stdenvNoCC.hostPlatform.isDarwin
    then "/usr/bin/open"
    else "${xdg-utils}/bin/xdg-open";
in
  stdenvNoCC.mkDerivation {
    pname = "mcp-oauth";
    version = "0.1.0";
    src = ../../../src;
    dontBuild = true;
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/bin" "$out/lib/mcp-oauth"
      cp *.py "$out/lib/mcp-oauth/"
      substituteInPlace "$out/lib/mcp-oauth/cli.py" --replace-fail '@gum@' '${lib.getExe gum}'
      substituteInPlace "$out/lib/mcp-oauth/daemon.py" --replace-fail '@notifier@' '${notifier}'
      substituteInPlace "$out/lib/mcp-oauth/login.py" --replace-fail '@browser@' '${browser}'
      printf '#!${python3}/bin/python3\n' > "$out/bin/mcp-oauth"
      cat >> "$out/bin/mcp-oauth" <<EOF
      import sys
      sys.path.insert(0, "$out/lib/mcp-oauth")
      from cli import main
      sys.exit(main())
      EOF
      chmod +x "$out/bin/mcp-oauth"
    '';
    passthru.updateTargetExempt = "built from the in-repo source; no upstream release";
    meta = {
      description = "Explicit OAuth account management for MCP services";
      license = lib.licenses.mit;
      mainProgram = "mcp-oauth";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
