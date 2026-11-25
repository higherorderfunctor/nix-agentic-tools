# Readers register by module merging, and every constructor resolves the same selection.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # Standalone construction evaluates the module files Home Manager and devenv do.
  mergeReaders = (import ../lib/default.nix).ai.credential-usage.mergeReaders {inherit pkgs lib;};
  inherit ((import ../../claude-code/lib/default.nix).ai.claude-code) usageModule usageReader;
  # Expectations read Claude's library, never the registration under test.
  shipped = usageReader {
    inherit pkgs;
    python-stack = pkgs.ai.generic.python-stack;
    # The shipped Reader bundles no CLI; it reads the `claude` on PATH.
    claude = pkgs.emptyDirectory;
  };
  # An ordinary derivation stands in for another owner's packaged Reader.
  fill = pkgs.hello;
  # Owners default every leaf, as Claude's own module does.
  owner = id: {
    ai.credentialUsage.readers.${id} = lib.mapAttrs (_: lib.mkDefault) {
      package = fill;
      endpoint = "https://owner.example";
      transports = ["cpa"];
    };
  };
  # Real backend imports exercise both wrappers.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  registered = evaluate: modules: (evaluate modules).config.ai.credentialUsage.readers;
  exe = reader: lib.getExe reader.package;
  # A caller's explicit Reader for Claude's id, at the priority a consumer uses.
  selection = {
    ai.credentialUsage.readers.claude = {
      package = fill;
      endpoint = "https://selected.example";
    };
  };
  # Each case fails on the wrong implementation its comment names.
  cases = backend: let
    registered' = registered backends.${backend};
    merged = contributions: overrides: mergeReaders {inherit contributions overrides;};
  in {
    # 119. Both ids keep their own package: a fixed vendor switch drops the new id.
    "a second owner registers a selectable fill" =
      builtins.all (readers:
        builtins.attrNames readers
        == ["claude" "sample"]
        && exe readers.sample == lib.getExe fill
        && readers.sample.endpoint == "https://owner.example"
        && readers.sample.transports == ["cpa"]
        && exe readers.claude == lib.getExe shipped
        && readers.claude.endpoint == "https://api.anthropic.com"
        && readers.claude.transports == ["direct" "cpa"])
      [
        (registered' [(owner "sample")])
        (merged [usageModule (owner "sample")] {})
      ];
    # 120. Two owners default one id: letting the last owner win evaluates here.
    # Force each leaf only: forcing a whole derivation overflows the evaluator.
    "two concrete fills for one id fail evaluation" =
      builtins.all (readers:
        !(builtins.tryEval (builtins.all (id:
          builtins.seq (exe readers.${id})
          (builtins.seq readers.${id}.endpoint (builtins.seq readers.${id}.transports true)))
        (builtins.attrNames readers))).success)
      [
        (registered' [(owner "claude")])
        (merged [usageModule (owner "claude")] {})
      ];
    # 121. An explicit selection wins and the shipped command is the same everywhere:
    # a constructor that ignores the selection returns the shipped command instead.
    "standalone, Home Manager and devenv resolve the same selected reader" =
      exe (registered' [selection]).claude
      == lib.getExe fill
      && exe (merged [usageModule] selection.ai.credentialUsage.readers).claude == lib.getExe fill
      && exe (registered' []).claude == lib.getExe shipped
      && exe (merged [usageModule] {}).claude == lib.getExe shipped;
    # 122. The selected endpoint survives both ways of constructing the registry.
    "a selected Reader keeps its endpoint" =
      (registered' [selection]).claude.endpoint
      == "https://selected.example"
      && (merged [usageModule] selection.ai.credentialUsage.readers).claude.endpoint == "https://selected.example";
  };
  failures = backend: lib.attrNames (lib.filterAttrs (_: passed: !passed) (cases backend));
  # Independent evaluations name the backend and each failed case.
  checks = lib.mapAttrs (backend: _:
    harness.mkTest "credential-usage-registration-${backend}" (
      lib.assertMsg (failures backend == []) "${backend}: ${lib.concatStringsSep "; " (failures backend)}"
    ))
  backends;
in {
  # A single owner property check covers both backends.
  checks.credential-usage-registration = pkgs.linkFarm "credential-usage-registration" (
    lib.mapAttrsToList (name: path: {inherit name path;}) checks
  );
}
