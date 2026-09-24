# Exercise repository ownership with the pinned devenv writers and AI observer.
{
  harness,
  inputs,
  instr,
  lib,
  materializer,
  pkgs,
  ...
}: let
  project = import ../../devenv.nix {
    config = {};
    inherit inputs lib pkgs;
  };
  runtime = harness.evalDevenv {
    ai = {
      inherit (project.ai) programs;
      claude = {
        enable = true;
        inherit (project.ai.claude) files;
      };
      codex = {
        enable = true;
        inherit (project.ai.codex) files;
      };
    };
    inherit (project) files;
  };
  targets = [".claude/rules/delegate-sizing-router.md" "AGENTS.md"];
  native = lib.evalModules {
    specialArgs = {inherit pkgs;};
    modules = [
      "${inputs.devenv}/src/modules/files.nix"
      ../../lib/ai/file-warnings.nix
      {
        options = {
          ai = lib.mkOption {type = lib.types.attrs;};
          devenv = {
            root = lib.mkOption {default = ".";};
            state = lib.mkOption {default = "./state";};
          };
          enterShell = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
          infoSections = lib.mkOption {type = lib.types.attrs;};
          lib = lib.mkOption {type = lib.types.attrs;};
          tasks = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};
        };
        config = {
          ai = {
            claude = {
              enable = true;
              files = runtime.config.ai.claude.files;
            };
            codex = {
              enable = true;
              files = runtime.config.ai.codex.files // {"conflict".content.text = "expected";};
            };
            internal.files = runtime.config.ai.internal.files;
          };
          files =
            lib.filterAttrs (name: _: builtins.elem name targets) runtime.config.files
            // {
              conflict.text = "expected";
            };
        };
      }
    ];
  };
  script = name: body:
    pkgs.writeShellScript name ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${body}
    '';
  scripts = pkgs.writeText "instruction-ownership-scripts.json" (builtins.toJSON {
    cleanup = script "ownership-cleanup" native.config.tasks."devenv:files:cleanup".exec;
    create = script "ownership-create" native.config.tasks."devenv:files".exec;
    inspect = script "ownership-inspect" native.config.enterShell;
    snapshot = script "ownership-snapshot" native.config.tasks."ai:delivery:observe-retired".exec;
  });
  inherit (import ../../dev/tasks/generate.nix {inherit instr lib pkgs;}) tasks;
in {
  checks.instruction-ownership = assert native.config.files."AGENTS.md".copyMode == "seed";
  assert native.config.files."AGENTS.md".source == "${instr.agents}/AGENTS.md";
  assert !(native.config.files ? ".claude/rules/delegate-sizing-router.md");
  assert builtins.elem "devenv:files" tasks."generate:instructions:materialize".after;
    pkgs.runCommand "instruction-ownership" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq pkgs.python3];
    } ''
      python ${./instruction-ownership.py} ${scripts} ${lib.getExe materializer} ${instr.agents}/AGENTS.md
      touch "$out"
    '';
}
