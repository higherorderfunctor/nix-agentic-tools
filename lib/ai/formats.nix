# How structured content becomes bytes, as a lookup rather than a fold.
#
# A factory writes `content.value = {…}; format = "json";` and is done: the
# router calls the renderer, and nothing below the delivery layer calls
# `builtins.toJSON` again. `sharedOk` is the other half of the same table —
# whether a format names a container the reconciler can own individual leaves
# inside, which is what makes a whole-file surface whole-file by statement
# rather than by which helper a factory happened to reach for.
{
  lib,
  pkgs,
}: rec {
  # A renderer returns CONTENT, in the same two tags an entry carries: literal
  # bytes, or a store path holding them. Returning a store path for toml and
  # yaml is deliberate — reading a generated file back at evaluation is
  # import-from-derivation, which this repository does not do, and the sinks
  # take a path just as happily as a string.
  table = {
    json = {
      render = _name: value: {text = builtins.toJSON value;};
      sharedOk = true;
    };
    # Markdown bodies are composed by lib/ai/transformers/ and arrive as
    # `content.text`; there is no value shape to render here.
    markdown = {
      render = null;
      sharedOk = false;
    };
    raw = {
      render = null;
      sharedOk = false;
    };
    toml = {
      render = name: value: {source = (pkgs.formats.toml {}).generate name value;};
      sharedOk = true;
    };
    yaml = {
      render = name: value: {source = (pkgs.formats.yaml {}).generate name value;};
      sharedOk = false;
    };
  };

  # A store name for a rendered file, derived from the target path. The `ai-`
  # prefix is not decoration: a store name may not begin with a period, and
  # plenty of these paths do.
  storeName = path: "ai-delivery-" + lib.replaceStrings ["/"] ["-"] path;

  render = {
    format,
    path,
    value,
  }:
    if table.${format}.render == null
    then
      throw ''
        ai delivery: "${path}" sets `content.value`, but format `${format}` has
        no renderer — its bytes come from `content.text` or `content.source`.
      ''
    else table.${format}.render (storeName path) value;
}
