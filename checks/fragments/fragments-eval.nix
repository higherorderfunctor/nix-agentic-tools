# Exercise the node constructors through a real transformer, not test handlers.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) checkRows mkTest rejectsChange;
  inherit (import ../../lib/fragments.nix {inherit lib;}) mkBlock mkInclude mkLink mkRaw;
  inherit ((import ../../lib/ai {inherit lib;}).transformers.claude) render;

  link = mkLink {
    label = "stack-fix";
    target = "skills/foo";
  };
  raw = mkRaw "hello";
  renderText = text: render {inherit text;};

  # Force the renderer's returned string; only the node discriminator changes
  # from the valid control, so rejection cannot be due to a missing raw field.
  rejectsDiscriminator = invalid:
    rejectsChange (node: renderText [node]) {
      inherit invalid;
      valid = raw;
      expected = "hello";
    };
in {
  checks.fragments-renderer = mkTest "fragments-renderer" (checkRows "fragment nodes and rendering" {
    "block preserves child order and uses the active link handler" =
      renderText [(mkBlock [(mkRaw "See ") link (mkRaw ".")])]
      == "See [stack-fix](skills/foo).";
    "include emits the import marker, not the bare path" =
      renderText [(mkInclude "foo/bar.md")] == "@foo/bar.md";
    "missing node kind must not default to raw" =
      rejectsDiscriminator (builtins.removeAttrs raw ["__nodeKind"]);
    "omitted link label is null, not absent or filled with the target" =
      mkLink {target = "skills/foo";}
      == {
        __nodeKind = "link";
        label = null;
        target = "skills/foo";
      };
    "top-level mixed nodes preserve adjacent raw text and dispatch the link" =
      renderText [(mkRaw "Use ") (mkRaw "the ") link (mkRaw " skill.")]
      == "Use the [stack-fix](skills/foo) skill.";
    "unregistered node kind must not be skipped or rendered as raw" =
      rejectsDiscriminator (raw // {__nodeKind = "unknown";});
  });
}
