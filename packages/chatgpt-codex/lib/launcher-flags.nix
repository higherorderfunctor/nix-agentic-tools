# Flags the launcher passes to Codex, per policy. mkCodex.nix builds the
# launcher from them; extract/rules.nix records them as reconcile `uses` of the
# root command's flags, so a Codex release that drops one there fails as
# `removed`.
{
  devenv = ["--no-daemon"];
  hookTrust = ["--config"];
}
