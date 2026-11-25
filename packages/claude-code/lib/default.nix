{
  ai.apps.mkClaude = import ./mkClaude.nix;
  ai.claude-code = {
    pythonModule = import ./python-module.nix;
    usageModule = ../modules/usage.nix;
    usageReader = import ./usage-reader.nix;
  };
}
