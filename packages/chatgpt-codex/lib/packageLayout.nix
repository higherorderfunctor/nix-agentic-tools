# Where chatgpt-codex puts upstream's complete Codex package inside its output.
# The one source for that path: package.nix installs there and publishes it as
# `passthru.codexPackage.root`, and the daemon selector (daemonSelect.nix)
# recognizes a `current` of exactly this shape as its own. mkCodex.nix pins
# only a package whose root matches, so it never writes a selection its
# selector could not release.
{
  root = "libexec/codex";
}
