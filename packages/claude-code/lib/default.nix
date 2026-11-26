{
  ai.apps.mkClaude = import ./mkClaude.nix;
  ai.claude-code = {
    # The Claude usage Reader's Python package, for one python-stack interpreter.
    pythonModule = import ./python-module.nix;
    # The packaged `claude-usage` command.
    usageReader = import ./usage-reader.nix;
  };
}
