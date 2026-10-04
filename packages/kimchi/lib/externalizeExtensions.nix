# Remove registration and its now-inert advertised toggle, never package code.
{
  externalizedExtensions,
  lib,
}:
lib.concatMapStrings (extension: ''
  substituteInPlace src/cli.ts \
    --replace-fail ${lib.escapeShellArg (extension.importLine + "\n")} "" \
    --replace-fail ${lib.escapeShellArg (extension.factoryLine + "\n")} ""
  substituteInPlace src/resources/definitions.ts \
    --replace-fail ${lib.escapeShellArg extension.resourceDefinition} ""
'')
externalizedExtensions
