# Settings → a config file with its secrets lifted out, for a launcher that
# resolves them at start. Needs only nixpkgs lib.
#
# `render { prefix; settings; }` drops every null, recursively and inside
# lists, and replaces each redact reference with a placeholder:
#
#   { content = <JSON text>; secrets = { <NAME> = <redact reference>; }; }
#
# NAME is `<prefix>_<PATH>`: the value's path (keys and list positions after
# nulls are dropped), upper-cased, every other character `_`. Two paths that
# give one name fail evaluation rather than share a secret.
#
# The placeholder is `{$NAME}`, the env-reference token lib/ai/mcpProxy.nix
# writes into its Caddyfile, and it is always a whole JSON string:
# `"{$NAME}"`. A launcher replaces that quoted token with the resolved value
# encoded as a JSON string, one rule for every owner. JSON text is also YAML
# 1.2, so a YAML reader takes the same file; it is text at evaluation, where
# `pkgs.formats.*.generate` gives a derivation and quotes `{$NAME}` its own way.
{lib}: let
  isReference = value: builtins.isAttrs value && builtins.attrNames value == ["_redact"];
  sanitize = segment:
    lib.concatStrings (map (c:
      if builtins.match "[A-Z0-9]" c != null
      then c
      else "_") (lib.stringToCharacters (lib.toUpper (toString segment))));
  # Concatenated, not interpolated: `$${` is Nix's escape for a literal `${`.
  placeholder = name: "{" + "$" + name + "}";

  # path → value → { value; secrets = [ { name; path; reference; } ]; }
  lift = prefix: path: value:
    if isReference value
    then let
      name = lib.concatMapStringsSep "_" sanitize ([prefix] ++ path);
    in {
      value = placeholder name;
      secrets = [
        {
          inherit name path;
          reference = value;
        }
      ];
    }
    else if builtins.isAttrs value
    then let
      kept = lib.filterAttrs (_: v: v != null) value;
      lifted = lib.mapAttrs (key: lift prefix (path ++ [key])) kept;
    in {
      value = lib.mapAttrs (_: entry: entry.value) lifted;
      secrets = lib.concatMap (entry: entry.secrets) (builtins.attrValues lifted);
    }
    else if builtins.isList value
    then let
      lifted = lib.imap0 (index: lift prefix (path ++ [index])) (lib.filter (v: v != null) value);
    in {
      value = map (entry: entry.value) lifted;
      secrets = lib.concatMap (entry: entry.secrets) lifted;
    }
    else {
      inherit value;
      secrets = [];
    };
in {
  # The launcher's substitution, for checks that load a render: each
  # placeholder in `content` replaced by `values.<NAME>` as a JSON string.
  fill = values: content: let
    names = builtins.attrNames values;
  in
    builtins.replaceStrings (map (name: builtins.toJSON (placeholder name)) names) (map (name: builtins.toJSON values.${name}) names) content;
  render = {
    prefix,
    settings,
  }: let
    lifted = lift prefix [] settings;
    byName = lib.groupBy (secret: secret.name) lifted.secrets;
    shared = lib.filterAttrs (_: secrets: builtins.length secrets > 1) byName;
  in
    if shared == {}
    then {
      content = builtins.toJSON lifted.value;
      secrets = lib.mapAttrs (_: secrets: (lib.head secrets).reference) byName;
    }
    else
      throw "lib/extracted/render: ${prefix}: paths share a placeholder name: ${lib.concatStringsSep "; " (lib.mapAttrsToList (name: secrets: "${name} ← ${lib.concatMapStringsSep ", " (secret: lib.concatMapStringsSep "." toString secret.path) secrets}")
          shared)}";
}
