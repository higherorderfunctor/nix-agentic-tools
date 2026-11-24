# Fill owners use the shared envelope and run their command against its fixture pair.
{
  ai.credential-usage = {
    conformanceCheck = import ./conformance.nix;
    pythonModule = import ./python-module.nix;
  };
}
