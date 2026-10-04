# `defaultText` for a module option whose default is this flake's package at
# `ai.<path>` (a dotted string: "devTools.glab"). Every such default reads
# `config.ai.internal.packages`, which is the consumer's `pkgs.ai` when this
# flake's overlay is applied and this flake's own build otherwise. One helper
# keeps that wording in one place, and keeps the literal attribute path out of
# module files.
{lib}: path:
lib.literalMD "`pkgs.ai.${path}` when this flake's overlay is applied, else this flake's build of it"
