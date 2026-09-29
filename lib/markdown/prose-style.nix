# Shared Markdown and YAML prose wrapping for treefmt and generated files.
# Prettier joins split code spans; the split-code-spans check must run before
# formatting because a mid-token newline becomes an undetectable space.
{proseWrap = "always";}
