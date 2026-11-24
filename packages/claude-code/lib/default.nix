{
  ai.apps.mkClaude = import ./mkClaude.nix;
  ai.claude-code = {
    pythonModule = import ./python-module.nix;
    usageReader = import ./usage-reader.nix;
  };
}
