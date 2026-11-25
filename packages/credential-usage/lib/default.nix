# Fill owners use the shared envelope and run their command against its fixture pair.
# Consumers of registered Readers merge owner contributions with `mergeReaders`.
let
  conformanceSuite = ../checks/conformance;
in {
  ai.credential-usage = {
    conformanceCheck = import ./conformance.nix;
    inherit conformanceSuite;
    mergeReaders = import ./readers.nix;
    pythonModule = import ./python-module.nix;
    readerModule = ../modules/common.nix;
    standaloneCheck = "${conformanceSuite}/standalone.py";
  };
}
