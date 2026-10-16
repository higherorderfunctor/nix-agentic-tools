# Kiro's migrated surfaces and the steering legacy drain on both backends.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm fromGeneratedTree markdownInput mkTest;
  files = import ../lib/files/default.nix {inherit lib pkgs;};
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  skill = ../../kiro-cli/checks/fixtures/kiro-steering/alpha.md;
  rule = {
    matcher = ["src/**"];
    text = "SCOPED-RULE";
  };
  evaluate = backend: count: enable:
    backends.${backend} {
      ai.kiro = {
        cli.enable = enable;
        rules = lib.genAttrs (lib.take count ["alpha" "beta"]) (_: rule);
      };
    };
  fixture = lib.mapAttrs (backend: _:
    map (step: let
      evaluated = evaluate backend step.count step.enable;
      inherit (evaluated) config;
      plan = lib.filter (item: item.method != "symlink" && lib.hasPrefix ".kiro/steering/" item.path) (files.normalize {
        inherit backend;
        files = config.ai.files;
        namespace = "ai";
        owners = config.ai.filesOwners;
      });
    in {
      inherit (config.ai.kiro) legacyLedgers;
      inherit plan;
      texts = lib.mapAttrs (_: entry: entry.content.text) config.ai.kiro._generatedFiles;
      native = lib.filter (lib.hasPrefix ".kiro/steering/") (builtins.attrNames (
        if backend == "hm"
        then config.home.file
        else config.files
      ));
    }) [
      {
        count = 2;
        enable = true;
      }
      {
        count = 1;
        enable = true;
      }
      {
        count = 0;
        enable = true;
      }
      {
        count = 0;
        enable = false;
      }
    ])
  backends;
in {
  checks = {
    ai-module-kiro-normalized-rules = mkTest "ai-module-kiro-normalized-rules" (
      lib.all (evaluate:
        lib.all (force: let
          evaluated = evaluate {
            ai.rules.inherited.text = "INHERITED-RULE";
            ai.kiro = {
              cli.enable = true;
              rules.local.text = "LOCAL-RULE";
              normalized.rules = (
                if force
                then lib.mkForce
                else lib.id
              ) {extra = rule;};
            };
          };
          inherit (evaluated) config;
          delivered = deliveredFiles config;
          inherited =
            if config ? home
            then ".kiro/steering/inherited.md"
            else "AGENTS.md";
          option = evaluated.options.ai.kiro.normalized.rules;
        in
          fromGeneratedTree ".kiro/steering/extra.md" delivered.".kiro/steering/extra.md"
          && lib.hasInfix "SCOPED-RULE" (markdownInput evaluated ".kiro/steering/extra.md").text
          && !option.internal
          && !option.readOnly
          && (
            if force
            then
              builtins.attrNames config.ai.kiro.normalized.rules
              == ["extra"]
              && !(delivered ? ".kiro/steering/inherited.md")
              && !(delivered ? ".kiro/steering/local.md")
            else delivered ? ${inherited} && lib.hasInfix "INHERITED-RULE" (markdownInput evaluated inherited).text
          )
          && lib.all (assertion: assertion.assertion) config.assertions) [false true]) [evalHm evalDevenv]
    );
    ai-module-kiro-single-file-skill = let
      source = pkgs.writeText "raw-skill.md" "#   Heading\n";
      path = ".kiro/skills/single/SKILL.md";
      delivered = map (evaluate:
        (deliveredFiles
          (evaluate {
            ai.kiro = {
              cli.enable = true;
              skills.single = source;
            };
          }).config).${
          path
        }) [evalHm evalDevenv];
    in
      assert lib.all (fromGeneratedTree path) delivered;
        pkgs.runCommandLocal "ai-module-kiro-single-file-skill" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          for delivered in ${lib.escapeShellArgs (map (file: file.source) delivered)}; do
            ${pkgs.diffutils}/bin/cmp ${source} "$delivered"
          done
          ${pkgs.coreutils}/bin/touch "$out"
        '';
    ai-module-kiro-steering = pkgs.runCommandLocal "ai-module-kiro-steering" {passthru.fixture = builtins.toJSON fixture;} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./kiro.py} \
        ${../lib/files}/engine.py ${pkgs.writeText "kiro-steering.json" (builtins.toJSON fixture)}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
    ai-module-kiro-surfaces = mkTest "ai-module-kiro-surfaces" (
      lib.all (backend: let
        evaluated = backends.${backend} {
          ai.kiro = {
            agents.reviewer = ''{"name":"reviewer"}'';
            cli.enable = true;
            context.text = "CONTEXT";
            native.agents.writer = {
              format = "markdown";
              prompt.text = "WRITE";
            };
            permissions = [
              {
                capability = "filesystem";
                effect = "allow";
              }
            ];
            rules.scoped = rule;
            skills.single = skill;
          };
        };
        inherit (evaluated) config;
        prefix = ".kiro/";
        paths =
          ["agents/reviewer.json" "agents/writer.md" "skills/single/SKILL.md" "steering/scoped.md"]
          ++ lib.optionals (backend == "hm") ["settings/cli.json" "settings/mcp.json" "settings/permissions.yaml" "steering/AGENTS.md"];
        delivered = deliveredFiles config;
      in
        builtins.attrNames config.ai.kiro._generatedFiles
        == lib.sort builtins.lessThan (map (path: prefix + path) paths)
        && lib.all (path: let
          target = prefix + path;
          entry = config.ai.files.${target};
        in
          config.ai.kiro.files ? ${target}
          && entry.executable == null
          && entry.mode == null
          && fromGeneratedTree target delivered.${target})
        (lib.subtractLists ["settings/cli.json" "settings/mcp.json"] paths)
        && config.ai.files.".kiro/steering/scoped.md".method
        == {
          devenv = "ro";
          hm = "symlink";
        }
        && lib.all (path: config.ai.files.${prefix + path}.method == "symlink") (lib.subtractLists ["settings/cli.json" "settings/mcp.json" "steering/scoped.md"] paths)
        && (markdownInput evaluated ".kiro/skills/single/SKILL.md").source == "${skill}"
        && lib.all (assertion: assertion.assertion) config.assertions) (builtins.attrNames backends)
    );
  };
}
