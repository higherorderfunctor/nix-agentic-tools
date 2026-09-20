# The delivery layer's option schema, declared once and spliced into every
# `options.ai.<runtime>` by `lib/ai/app/mkBackendTransform.nix`.
#
# A runtime describes WHAT it delivers and WHO materializes it; the router
# (`lib/ai/deliver.nix`) and the two adapters decide how that lands on a
# backend. Nothing here is a function-valued seam, so a consumer can read the
# whole description out of the option tree and override any field of it with
# the ordinary module-system priorities.
{lib}: let
  deliveryMethod = import ./deliveryMethod.nix {inherit lib;};

  # Which renderer turns a structured `content.value` into bytes, and — for a
  # document the harness also writes — which container the reconciler owns
  # leaves inside. `raw` is the default because most files carry their bytes
  # directly.
  formats = ["json" "markdown" "raw" "toml" "yaml"];

  # A consumer fact usually holds on both backends. When it does not, the
  # exception is keyed by backend; `either` keeps the common case a bare bool
  # and adds no type a home-manager reader has not met.
  #
  # The per-backend arm is a SUBMODULE with both keys required, not an
  # `attrsOf bool`: the rule reads `value.<backend>`, so a fact stated for one
  # backend only — or under a typo'd key — used to surface as a bare
  # `attribute 'devenv' missing` naming no option at all. Requiring both is
  # also the honest shape, because a fact that holds on one backend and is
  # unstated on the other has no default to fall back to.
  factType = lib.types.either lib.types.bool (lib.types.submodule {
    options = {
      devenv = lib.mkOption {
        type = lib.types.bool;
        description = "The fact, as it holds for the devenv backend.";
      };
      hm = lib.mkOption {
        type = lib.types.bool;
        description = "The fact, as it holds for the Home Manager backend.";
      };
    };
  });

  # The bytes, as a TAGGED sum rather than a pair of nullable siblings. Three
  # things follow, and each one is load-bearing:
  #   - the text/source exclusion becomes the type instead of a hand-rolled
  #     check that had to be repeated in the option's `apply`;
  #   - `content = lib.mkDefault {text = …;}` from a generator survives a
  #     consumer's definition of a SIBLING field, because priority now applies
  #     to the content option alone rather than to the whole entry;
  #   - a consumer's `content.source` still replaces a defaulted
  #     `content.text`, so the tag never sees two definitions at once.
  #
  contentType = lib.types.attrTag {
    run = lib.mkOption {
      type = lib.types.lines;
      description = ''
        A shell body that WRITES the file when the writer runs, for bytes that
        cannot exist in the store — a credential substituted in at write time,
        say. Owned copies and reconciled documents only: a symlink has no write
        step to run it in. The reconciler executes it with the interpreter its
        plan pins, never the one a PATH happens to resolve.
      '';
    };
    source = lib.mkOption {
      type = lib.types.path;
      description = "Store-backed bytes: a path whose contents become the file.";
    };
    text = lib.mkOption {
      type = lib.types.str;
      description = "Literal bytes.";
    };
    value = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      description = ''
        Structured content, rendered into bytes by `format`. Two definitions at
        equal priority merge leaf-wise and a divergent leaf conflicts naming
        the option path, which is exactly the contract a document several
        modules contribute to needs — and the reason content is one tagged
        option rather than one opaque value.
      '';
    };
  };

  fileEntry = lib.types.submodule {
    options = {
      content = lib.mkOption {
        type = lib.types.nullOr contentType;
        default = null;
        description = ''
          The bytes this file carries, tagged with where they come from.

          `text` and `source` are contributed WHOLE by a generator, at
          `mkDefault`, with every sibling field left at ordinary priority:
          that is what lets a consumer change HOW a generated file lands
          without restating WHAT is in it.

          A `value` document is the exception, and it is measured rather than
          reasoned: `content = mkDefault {value = …;}` and
          `content.value = mkDefault {…}` BOTH lose every generated leaf the
          moment a consumer defines one of its own, because `filterOverrides`
          keeps only the priority-100 definitions and the generated leaves
          leave with the definition it drops. A document contributes its
          leaves at ordinary priority, or one `mkDefault` per LEAF
          (`content.value.<leaf> = lib.mkDefault …`) — that is the shape that
          merges leaf-wise and survives.
        '';
      };
      entry = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Which writer of `ai.<runtime>.activation` materializes this file.
          Required for a file that is copied or reconciled rather than
          symlinked, because those need something that also retracts it.
        '';
      };
      executable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = false;
        description = ''
          Whether the materialized file should be executable. `null` leaves the
          mode alone, which is what a tree of source files needs: a skill that
          ships a script would otherwise have its executable bit cleared at
          link time. Symlinked files only; an owned copy states `mode`.
        '';
      };
      facts = {
        harnessWrites = lib.mkOption {
          type = factType;
          default = false;
          description = ''
            The CLI itself rewrites this file while it runs, so the only way to
            keep both sides' edits is to own the declared leaves inside it.
            Stated only where it is true.
          '';
        };
        symlinkReadable = lib.mkOption {
          type = factType;
          default = true;
          description = ''
            The CLI follows a store symlink at this path. Stated only where it
            is false — a scan that keeps only regular files, or a consumer that
            reads a project-local path it will not follow out of the tree.
          '';
        };
      };
      format = lib.mkOption {
        type = lib.types.enum formats;
        default = "raw";
        description = ''
          Which renderer turns structured content into bytes. For a file whose
          leaves are reconciled it also names the on-disk container, which is
          why only `json` and `toml` can carry one.
        '';
      };
      ledger = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Which of that writer's declared ledgers claims this file. The
          ledger's own codec and path live on the writer, so a ledger no file
          claims still produces a valid empty target — which is how a path is
          released rather than abandoned.
        '';
      };
      method = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum deliveryMethod.methods);
        default = null;
        description = ''
          How this file lands. `null` asks `ai.<runtime>.methodFor`, which is
          the normal case: a runtime states the consumer FACTS and lets the
          rule decide. An explicit value is the light per-file exception and
          beats the rule. It is resolved in the router, never at type level,
          so `lib.mkForce` on this field and on `methodFor` both work.
        '';
      };
      mode = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "0?[0-7]{3}");
        default = null;
        description = ''
          Octal permissions imposed on every write. Owned copies and
          reconciled documents only; absent, an existing file keeps the mode it
          has and a new one is created private to the user.
        '';
      };
      recursive = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          `content.source` is a directory whose leaves land individually. FALSE
          with a directory source means the DIRECTORY itself becomes the
          symlink, which is what a CLI that discovers a skill by following one
          needs.
        '';
      };
      sink = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["files" ".claude/settings.json" "json"];
        description = ''
          For a file handed upstream instead of written here, the attribute
          path of the option that owns it. That is how a surface delegated to
          another module still appears in this runtime's delivery description
          rather than vanishing from it.
        '';
      };
    };
  };

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

          Read for a `command` writer only. A writer with `ledgers` is
          positioned by the reconciler itself — which takes exactly the
          default's two edges — so stating anything else there is an error
          rather than a silent no-op.
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
  # `null` suppresses a generated entry, and it has to beat a record at the
  # SAME priority to keep doing so.
  #
  # Generated CONTENT is contributed at `mkDefault` while the entry around it
  # stays at ordinary priority — that is what lets a consumer change how a
  # generated file lands without restating its bytes. The cost is that the
  # generated entry is no longer weaker than a consumer's definition, so a
  # plain `null` tombstone would meet a record at priority 100 and the module
  # system would report the option as defined both null and not null. Nothing
  # about the tombstone was supposed to change, so `null` absorbs: a
  # definition that suppresses the file wins over one that describes it, at
  # equal priority, and `filterOverrides` still settles unequal ones first.
  suppressible = elemType: let
    base = lib.types.nullOr elemType;
  in
    base
    // {
      # Retain the submodule's option metadata: upstream delivery aliases the
      # surviving content definitions so their priorities reach the host too.
      merge = {
        __functor = self: loc: defs: (self.v2 {inherit loc defs;}).value;
        v2 = {
          loc,
          defs,
        }:
          if lib.any (definition: definition.value == null) defs
          then {
            headError = null;
            value = null;
            valueMeta = {};
          }
          else base.merge.v2 {inherit loc defs;};
      };
      substSubModules = modules: suppressible (elemType.substSubModules modules);
    };
in {
  inherit formats;
  fileMapType = lib.types.attrsOf (suppressible fileEntry);
  writerMapType = lib.types.attrsOf writer;
}
