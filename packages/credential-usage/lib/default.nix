# Fill owners run their command against its fixture pair; consumers of registered Readers merge owner contributions with `mergeReaders`.
{
  ai.credential-usage = {
    conformanceCheck = import ./conformance.nix;
    conformanceSuite = ../checks/conformance;
    mergeReaders = import ./readers.nix;
    pythonModule = import ./python-module.nix;
    readerModule = ../modules/common.nix;
  };
}
