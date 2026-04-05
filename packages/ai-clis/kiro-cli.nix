# Kiro CLI — pre-built binary from AWS release channel.
{
  final,
  prev,
  nv,
}:
  prev.kiro-cli.overrideAttrs (attrs: {
    inherit (nv) src version;

    nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [final.makeWrapper];

    postFixup =
      (attrs.postFixup or "")
      + ''
        wrapProgram $out/bin/kiro-cli --set TERM xterm-256color
        wrapProgram $out/bin/kiro-cli-chat --set TERM xterm-256color
      '';

    meta =
      prev.kiro-cli.meta
      // {
        changelog = builtins.replaceStrings [prev.kiro-cli.version] [nv.version] prev.kiro-cli.meta.changelog;
      };
  })
