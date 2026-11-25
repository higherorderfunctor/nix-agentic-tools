# Fill owners use the shared envelope and run their command against its fixture pair.
# Consumers of registered Readers merge owner contributions with `mergeReaders`.
{
  ai.credential-usage = {
    conformanceCheck = import ./conformance.nix;
    mergeReaders = import ./readers.nix;
    pythonModule = import ./python-module.nix;
    readerModule = ../modules/common.nix;
    standaloneCheck = "${../checks/conformance}/standalone.py";
  };
}
