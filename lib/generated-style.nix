# One house style definition for generated files and repository treefmt.
{
  biome = {
    indentStyle = "space";
    indentWidth = 2;
  };
  prettier = import ./markdown/prose-style.nix;
}
