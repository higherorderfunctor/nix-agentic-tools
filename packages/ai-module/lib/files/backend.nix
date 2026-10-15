# What both backend modules derive from `ai.files2`: one normalized plan, the
# native link map, the engine invocation and the generated activation entries.
{
  lib,
  pkgs,
}: {
  backend,
  config,
  root,
  state,
}: let
  files2 = import ./default.nix {inherit lib pkgs;};
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  plan = files2.normalize {
    inherit backend;
    files = config.ai.files2;
    namespace = "ai";
  };
  planFile = pkgs.writeText "files2-ai-plan.json" (builtins.toJSON plan);
  links = builtins.filter (item: item.method == "symlink") plan;
  sourceOf = item: item.content.source or (item.content.rendered or (pkgs.writeText "files2-link" item.content.text));
  # Generated entries are added by the lowering, never defined into the
  # `ai.activation2` option, so no caller priority can remove them.
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
    export FILES2_BASH=${pkgs.bash}/bin/bash
    ${python}/bin/python3 -I ${./.}/engine.py \
      --plan ${planFile} --root "${root}" \
      --state "${state}" \
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
  duplicate = reserved: lib.findFirst (name: builtins.hasAttr name config.ai.activation2) null reserved;
  # Always emitted so removing the last file still drains (N->0). The engine
  # deletes its state once nothing is owned, so for an empty map a missing
  # state file means nothing to retract and Python never starts. A nonempty
  # map always runs prune: its parent check refuses a symlinked parent before
  # HM links into it.
  prune = generatedEntry {
    after = [];
    before = ["linkCheck"];
    command =
      lib.optionalString (plan == []) ''
        [ -e "${state}" ] || exit 0
      ''
      + phase "prune";
  };
}
