# Golden tests for lib/fragments.nix node constructors + mkRenderer.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) checkRows mkTest rejectsChange;
  inherit (import ../../lib/fragments.nix {inherit lib;}) defaultHandlers mkBlock mkInclude mkLink mkRaw mkRenderer;

  link = mkLink {
    label = "stack-fix";
    target = "skills/foo";
  };
  raw = mkRaw "hello";
  renderText = text:
    mkRenderer {
      frontmatterData = _: {};
      handlers =
        defaultHandlers
        // {
          include = _ctx: node: "<<include:${node.path}>>";
          link = _ctx: node: "[${node.label}](${node.target})";
        };
      name = "identity";
    } {} {inherit text;};

  # Force the renderer's returned string; only the node discriminator changes
  # from the valid control, so rejection cannot be due to a missing raw field.
  rejectsDiscriminator = invalid:
    rejectsChange (node: renderText [node]) {
      inherit invalid;
      valid = raw;
      expected = "hello";
    };
in {
  checks = {
    fragments-constructors = mkTest "fragments-constructors" (checkRows "fragment constructor shapes" {
      "block retains ordered children" =
        mkBlock [(mkRaw "a") (mkRaw "b")]
        == {
          __nodeKind = "block";
          nodes = [
            {
              __nodeKind = "raw";
              text = "a";
            }
            {
              __nodeKind = "raw";
              text = "b";
            }
          ];
        };
      "include retains path" =
        mkInclude "path/to/file.md"
        == {
          __nodeKind = "include";
          path = "path/to/file.md";
        };
      "link defaults an omitted label to null" =
        mkLink {target = "skills/foo";}
        == {
          __nodeKind = "link";
          label = null;
          target = "skills/foo";
        };
      "link retains an explicit label" =
        link
        == {
          __nodeKind = "link";
          label = "stack-fix";
          target = "skills/foo";
        };
      "raw retains text" =
        raw
        == {
          __nodeKind = "raw";
          text = "hello";
        };
    });

    fragments-renderer = mkTest "fragments-renderer" (checkRows "fragment rendering" {
      "bare string remains plain text" = renderText "plain text" == "plain text";
      "block renders children in order" = renderText [(mkBlock [(mkRaw "outer-a ") (mkRaw "outer-b")])] == "outer-a outer-b";
      "empty string stays empty" = renderText "" == "";
      "include uses the transformer handler" = renderText [(mkInclude "foo/bar.md")] == "<<include:foo/bar.md>>";
      "mixed nodes dispatch the link handler in order" = renderText [(mkRaw "Use the ") link (mkRaw " skill.")] == "Use the [stack-fix](skills/foo) skill.";
      "multiple raw nodes preserve spacing and order" = renderText [(mkRaw "hello ") (mkRaw "world")] == "hello world";
      "node missing __nodeKind is rejected" = rejectsDiscriminator (builtins.removeAttrs raw ["__nodeKind"]);
      "unregistered node kind is rejected" = rejectsDiscriminator (raw // {__nodeKind = "unknown";});
    });
  };
}
