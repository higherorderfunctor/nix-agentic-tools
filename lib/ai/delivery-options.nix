# The delivery layer's option schema, declared once and spliced into every
# `options.ai.<runtime>` by `lib/ai/app/mkBackendTransform.nix`.
#
# A runtime describes WHAT it delivers and WHO materializes it; the router
# (`lib/ai/deliver.nix`) and the two adapters decide how that lands on a
# backend. Nothing here is a function-valued seam, so a consumer can read the
# whole description out of the option tree and override any field of it with
# the ordinary module-system priorities.
{lib}: let
  # A writer's IDENTITY, declared under the runtime's `enable` gate and never
  # inferred from the files that happen to exist this generation. That is
  # what makes taking a surface from N entries to zero correct by
  # construction: the writer, its ledgers and an EMPTY target all survive, and
  # an empty target is how `lib/ai/own.nix` releases a path. A writer
  # inferred from live files emits nothing at zero files, which is the prune
  # leak the reconciler exists to have fixed.
  writer = lib.types.submodule ({name, ...}: {
    options = {
      after = lib.mkOption {
        type = lib.types.listOf (lib.types.enum ["files" "secrets"]);
        default = ["files"];
        description = ''
          Abstract ordering edges this writer runs after; the adapter maps each
          token to the node its backend actually has. `files` becomes Home
          Manager's `linkGeneration` and devenv's `devenv:files:cleanup`.
          `secrets` becomes Home Manager's `sops-nix`, a dangling-tolerant edge
          that leaves the choice of secret manager to the consumer, and is
          dropped on devenv, which has no such node.
        '';
      };
      afterNodes = lib.mkOption {
        type = lib.types.submodule {
          options = {
            devenv = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Literal devenv task names this writer also runs after.";
            };
            hm = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Literal Home Manager activation entries this writer also runs after.";
            };
          };
        };
        default = {};
        description = ''
          Escape hatch for an ordering node no `after` token names. It is
          ADDITIVE to the token edges rather than a replacement for them, so a
          writer that needs one extra node keeps the portable ordering it
          already had.
        '';
      };
      before = lib.mkOption {
        type = lib.types.listOf (lib.types.enum ["linkCheck" "shell"]);
        default = ["shell"];
        description = ''
          Abstract ordering edges this writer runs before. `linkCheck` becomes
          Home Manager's `checkLinkTargets`, which is where work that deletes a
          real file has to run so link generation can take the path over.
          `shell` becomes devenv's `devenv:enterShell`, plus the conditional
          `devenv:files` edge the adapter adds when the project declares any
          files at all.
        '';
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = ''
          A bespoke body for work that owns no files, such as migrating a
          previous layout's links. The adapter wraps it in a strict subshell,
          so it must never run `exit`: that would truncate the whole
          concatenated activation script rather than failing this entry.
          Mutually exclusive with `ledgers`, which is what an owned file
          declares instead.
        '';
      };
      entry = lib.mkOption {
        type = lib.types.either lib.types.str (lib.types.attrsOf lib.types.str);
        default = name;
        example = lib.literalExpression ''{hm = "kiroMcpJson"; devenv = "ai:kiro:materialize-mcp";}'';
        description = ''
          The literal name this writer lowers to — a Home Manager activation
          entry or a devenv task — keyed by backend when the two differ. It is
          a consumer ordering contract and is never derived from a
          configuration value: a derived name silently breaks every consumer
          that ordered against the old one.
        '';
      };
      ledgers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            codec = lib.mkOption {
              type = lib.types.enum ["dir" "json" "toml"];
              description = "Which container `lib/ai/own.py` owns units inside: whole files in a directory, or leaves of a JSON or TOML document.";
            };
            path = lib.mkOption {
              type = lib.types.str;
              description = "The container's path, relative to the backend root (HOME for Home Manager, the project root for devenv).";
            };
          };
        });
        default = {};
        description = ''
          EVERY ledger this writer has ever owned, keyed by its literal name.
          A ledger no file claims this generation still lowers to a valid EMPTY
          target, which is how ownership of a path is RELEASED — so retiring a
          surface, pruning the last file out of a directory and handing a
          document over between two write modes all need no retirement-specific
          code. The codec and path live here rather than on the file for that
          reason: a retired ledger has no live file left to read them from.
        '';
      };
      pruneEntry = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.attrsOf lib.types.str));
        default = null;
        description = ''
          Home Manager's second entry name, required whenever any ledger has
          codec `dir`. A real file this writer owns must be gone before
          `checkLinkTargets`, and a new one may only appear after
          `linkGeneration`, so the two phases are two entries. devenv has one
          task and ignores this.
        '';
      };
    };
  });
in {
  writerMapType = lib.types.attrsOf writer;
}
