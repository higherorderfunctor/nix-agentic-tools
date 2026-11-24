# Checks and routing helpers pass pkgs and python-stack to build the module
# for their chosen interpreter through this public library entry.
{
  ai.credential-usage.pythonModule = import ./python-module.nix;
}
