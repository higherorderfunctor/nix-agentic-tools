# Flags the launcher passes to Codex, per policy. mkCodex.nix builds the
# launcher from them; extract/rules.nix records them as reconcile `uses`, so a
# Codex release that drops one fails as `removed`.
{
  devenv = ["--no-daemon"];
  hookTrust = ["--config"];
}
