# What both backend modules derive from `ai.files`: one normalized plan, the
# native link map, the engine invocation and the generated activation entries.
{
  lib,
  pkgs,
}: {
  backend,
  config,
  root,
  # Parent of the engine state and of the legacy ownership ledgers it imports.
  stateRoot,
}: let
  fileLib = import ./default.nix {inherit lib pkgs;};
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  plan = fileLib.normalize {
    inherit backend;
    files = config.ai.files;
    namespace = "ai";
    owners = config.ai.filesOwners;
  };
  planFile = pkgs.writeText "files-ai-plan.json" (builtins.toJSON plan);
  links = builtins.filter (item: item.method == "symlink") plan;
  sourceOf = item: item.content.source or (item.content.rendered or (pkgs.writeText "files-link" item.content.text));
  # Generated entries are added by the lowering, never defined into the
  # `ai.activation` option, so no caller priority can remove them.
  generatedEntry = attrs:
    {
      afterNodes = {
        devenv = [];
        hm = [];
      };
      beforeNodes = {
        devenv = [];
        hm = [];
      };
      enable = true;
      name = {
        devenv = null;
        hm = null;
      };
      runWhenDisabled = true;
    }
    // attrs;
  phase = name: ''
    export FILES_BASH=${pkgs.bash}/bin/bash
    ${python}/bin/python3 -I ${./.}/engine.py \
      --plan ${planFile} --root "${root}" \
      --state "${stateRoot}/files/ai.json" \
      --legacy-plan ${lib.escapeShellArg (builtins.toJSON config.ai.legacyLedgers)} \
      --legacy-state "${stateRoot}" \
      --phase ${name}
  '';
in {
  inherit generatedEntry links phase plan python;
  native = builtins.listToAttrs (map (item: {
      name = item.path;
      value =
        {source = sourceOf item;}
        // lib.optionalAttrs (item.executable != null) {inherit (item) executable;};
    })
    links);
  usesRun = builtins.any (item: item.content ? run) plan;
  # A caller key on a reserved generated name is refused, not merged.
  duplicate = reserved: lib.findFirst (name: builtins.hasAttr name config.ai.activation) null reserved;
  # Always emitted so removing the last file still drains (N->0). The engine
  # deletes its state once nothing is owned, and each old ledger once it is
  # imported, so for an empty map neither file existing means nothing to
  # retract and Python never starts. A nonempty map always runs prune: its
  # parent check refuses a symlinked parent before HM links into it.
  prune = generatedEntry {
    after = [];
    before = ["linkCheck"];
    command =
      lib.optionalString (plan == []) ''
        [ -e "${stateRoot}/files/ai.json" ]${lib.concatMapStrings (ledger: " || [ -e \"${stateRoot}\"/${lib.escapeShellArg ledger.ledger} ]") config.ai.legacyLedgers} || exit 0
      ''
      + phase "prune";
  };
}
