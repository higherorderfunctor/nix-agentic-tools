# Runtime contract: the pinned Codex refuses to save into a Nix-owned
# config.toml and leaves the link alone.
#
# Both backends deliver config.toml as a store symlink (mkCodex.nix). That is
# the right method only because every Codex config writer resolves the link
# and writes its temporary beside the link's TARGET, so a save into the store
# fails loudly and nothing diverges from the declaration. The daemon's
# settings.json writer renames over the path instead, which is why that file
# is a copy. A Codex release that moved config writes to rename-over-link
# would silently swap the link for a writable file; this check fails that
# update PR first.
#
# The target sits in a read-only directory standing in for the store, which a
# user cannot write: the builder's permissions on the sandbox's own store view
# are not a user's. Offline and with no model call: `codex mcp add` only edits
# config.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  codex = harness.aiStubs.chatgpt-codex;
  delivered = (harness.evalHm {ai.codex.enable = true;}).config.home.file.".codex/config.toml".source;
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    chatgpt-codex-readonly-config = pkgs.runCommand "chatgpt-codex-readonly-config" {} ''
      fail() {
        echo "FAIL: $*" >&2
        exit 1
      }
      export HOME="$TMPDIR/home"
      export CODEX_HOME="$HOME/.codex"
      mkdir -p "$CODEX_HOME" "$TMPDIR/owned"
      cp ${delivered} "$TMPDIR/owned/config.toml"
      chmod 444 "$TMPDIR/owned/config.toml"
      chmod 555 "$TMPDIR/owned"
      ln -s "$TMPDIR/owned/config.toml" "$CODEX_HOME/config.toml"

      if timeout 60 ${codex}/bin/codex mcp add probe -- true < /dev/null > stdout 2> stderr; then
        fail "codex mcp add saved into a Nix-owned config.toml: $(cat stdout stderr)"
      fi
      grep -qF "failed to persist config" stderr || fail "the refused save did not report why: $(cat stderr)"
      [ -L "$CODEX_HOME/config.toml" ] || fail "the save replaced the config.toml link"
      [ "$(readlink "$CODEX_HOME/config.toml")" = "$TMPDIR/owned/config.toml" ] \
        || fail "the link now points at $(readlink "$CODEX_HOME/config.toml")"
      cmp ${delivered} "$TMPDIR/owned/config.toml" || fail "the declared config.toml changed"
      echo "ok: codex mcp add fails against a Nix-owned config.toml and the link survives" > "$out"
    '';
  };
}
