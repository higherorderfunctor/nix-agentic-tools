# Shared Markdown and YAML prose wrapping for treefmt and generated files.
# Prettier launders a mid-token split into a space no check catches, so prevent
# it at authoring time; see the markdown-formatting fragment.
{proseWrap = "always";}
