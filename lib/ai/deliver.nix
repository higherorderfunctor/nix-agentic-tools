# The delivery router: the one place where a runtime's delivery description
# becomes backend configuration.
#
# Both adapters call it, so everything that is not literally "which option name
# does this backend use" is decided once, here. It knows nothing about any
# runtime — its inputs are `ai.<runtime>.activation`, `ai.<runtime>.files` and
# the backend name — and no runtime may call it, which is what keeps the four
# sink attribute paths adapter-owned.
{
  lib,
  pkgs,
}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  deliveryMethod = import ./deliveryMethod.nix {inherit lib;};
  formats = import ./formats.nix {inherit lib pkgs;};
  helpers = import ./hm-helpers.nix {inherit lib;};
  runtimeFiles = import ./runtime-files.nix {inherit lib;};

  # The methods this layer delivers today. `upstream` is declared and not
  # routed: it is how a surface another module owns stays visible in the
  # delivery description, and it lands with the factory that needs it.
  owningMethods = ["copy-ro" "shared"];
  routed = ["copy-ro" "shared" "symlink"];

  # Abstract ordering tokens → the node each backend actually has. A token with
  # no node on this backend is DROPPED rather than translated into a name that
  # backend's runner would reject: devenv has no secret-provider node at all,
  # and a dangling task reference is a hard error there.
  afterTokens = {
    devenv.files = "devenv:files:cleanup";
    hm = {
      files = "linkGeneration";
      secrets = "sops-nix";
    };
  };
  beforeTokens = {
    devenv.shell = "devenv:enterShell";
    hm.linkCheck = "checkLinkTargets";
  };
in
  {
    backend,
    cfg,
    config,
    runtime,
  }: let
    edges = tokens: names: lib.filter (node: node != null) (map (token: tokens.${backend}.${token} or null) names);

    # A writer's entry name may differ per backend, and both spellings are
    # literals a consumer orders against.
    nameFor = value:
      if builtins.isString value
      then value
      else value.${backend};

    # An entry a consumer suppressed with `null` is not a file; everything
    # below sees live entries only.
    live = lib.filterAttrs (_path: entry: entry != null) cfg.files;

    # The ONE place a method is resolved. Not at type level and not in an
    # `apply`: both would read a sibling option while the option they belong to
    # is still merging, and `ai.<runtime>.files` carries an `apply` of its own.
    # Here `cfg` is finished, so `mkForce` on `method` and on `methodFor` both
    # work and compose.
    resolve = path: entry:
      entry
      // {
        inherit path;
        method =
          if entry.method != null
          then entry.method
          else
            cfg.methodFor {
              inherit backend path;
              inherit (entry) facts;
              default = deliveryMethod.byRule;
            };
        # Structured content becomes bytes once, here. The ORIGINAL content
        # stays: a reconciled document declares the VALUE it owns leaves of,
        # and that value cannot be recovered from the bytes.
        rendered =
          if entry.content ? value
          then
            formats.render {
              inherit (entry) format;
              inherit path;
              inherit (entry.content) value;
            }
          else entry.content;
      };
    resolved = lib.mapAttrs resolve live;
    bucket = method: lib.filterAttrs (_path: entry: entry.method == method) resolved;
    # ── copy-ro and shared: one reconciler bundle per writer ──────────────
    #
    # A writer that owns files is a bundle of TARGETS, one per ledger it has
    # ever declared — not one per file that exists this generation. A ledger no
    # file claims lowers to an EMPTY target, which is how the reconciler
    # releases a path: the retirement of a surface, the last file leaving a
    # directory, and a document handed between two write modes are all the same
    # ordinary reconcile, with no retirement-specific code anywhere.
    owningEntries =
      lib.filter (entry: entry.entry != null && entry.ledger != null)
      (lib.attrValues (lib.filterAttrs (_path: entry: lib.elem entry.method owningMethods) resolved));
    claimsOf = writerName: lib.filter (entry: entry.entry == writerName) owningEntries;
    # The reconciler's own content vocabulary: a store path, literal bytes, or
    # a program that writes them.
    unitContent = entry:
      (
        if entry.rendered ? source
        then {store = entry.rendered.source;}
        else if entry.rendered ? run
        then {inherit (entry.rendered) run;}
        else {inherit (entry.rendered) text;}
      )
      // lib.optionalAttrs (entry.mode != null) {inherit (entry) mode;};
    targetsFor = writerName: writer:
      lib.mapAttrsToList (
        ledger: declaration: let
          claiming = lib.filter (entry: entry.ledger == ledger) (claimsOf writerName);
        in
          {
            inherit ledger;
            inherit (declaration) codec path;
          }
          // {
            units =
              if declaration.codec == "dir"
              then
                lib.listToAttrs (map (entry:
                  lib.nameValuePair (baseNameOf entry.path) (unitContent entry))
                claiming)
              else if claiming == []
              then {}
              # A document's declaration always travels as JSON, whatever the
              # on-disk codec: the reconciler parses `units.text` with a JSON
              # reader and the codec names only the container it writes into.
              else let
                entry = lib.head claiming;
              in
                if entry.rendered ? run
                then unitContent entry
                else
                  {text = builtins.toJSON entry.content.value;}
                  // lib.optionalAttrs (entry.mode != null) {inherit (entry) mode;};
          }
      )
      writer.ledgers;
    # `own` already orders itself after the backend's file node, so passing the
    # `files` token again would name that node twice.
    bundleAfterEdges = writer: edges afterTokens (lib.filter (token: token != "files") writer.after) ++ writer.afterNodes.${backend};
    owningWriters = lib.filterAttrs (_name: writer: writer.command == null && writer.ledgers != {}) cfg.activation;
    bundles =
      lib.mapAttrsToList (
        name: writer:
          helpers.mkOwnBundle {
            inherit backend pkgs runtime;
            after = bundleAfterEdges writer;
            declared =
              lib.listToAttrs (map (entry: lib.nameValuePair entry.path entry.content.value)
                (lib.filter (entry: entry.method == "shared" && entry.content ? value) (claimsOf name)));
            entryNames =
              {write = nameFor writer.entry;}
              // lib.optionalAttrs (backend == "hm" && writer.pruneEntry != null) {
                prune = nameFor writer.pruneEntry;
              };
            hasFiles = (config.files or {}) != {};
            python = formats.pythonFor writer.ledgers;
            targets = targetsFor name writer;
          }
      )
      owningWriters;
    # Merged into CONSTANT attribute paths: a list of fragments whose length
    # comes from `cfg.activation` forces that option while the module system is
    # still collecting the definitions it is made of.
    mergeBundles = path: lib.foldl' (merged: bundle: merged // lib.attrByPath path {} bundle) {} bundles;
  in {
    afterEdges = writer: edges afterTokens writer.after ++ writer.afterNodes.${backend};
    beforeEdges = writer: edges beforeTokens writer.before;

    # A bespoke body is spliced into one script the backend also fills with
    # other people's code — home-manager concatenates every activation entry —
    # so the flags it sets must not outlive it. The subshell is that boundary,
    # and it is also why a failing body ends non-zero for the caller's `set -e`
    # instead of running `exit`, which would truncate the whole script.
    commandBody = writer:
      aiCommon.scopedActivation ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${writer.command}
      '';

    # Writers that own no files at all: their whole product is the body.
    commands = lib.filterAttrs (_name: writer: writer.command != null) cfg.activation;

    # `tasks."devenv:files"` exists only when the project declares files, and
    # devenv's runner hard-errors on a dangling reference, so that edge stays
    # conditional. It is read here, in a value the file buckets never consult,
    # because a fragment that decided WHETHER to write `config.files` by
    # reading `config.files` is a genuine cycle.
    hasFiles = (config.files or {}) != {};

    inherit nameFor;

    # The backend's own store-symlink primitive, in the shape both file sinks
    # take. Home Manager recurses a directory source itself; devenv has no such
    # primitive, so the router walks the tree and emits one entry per leaf —
    # the leaves are ordinary entries, so `recursive` is off for each of them.
    symlinkEntries =
      lib.concatMapAttrs (
        path: entry:
          if entry.recursive && backend == "devenv"
          then
            lib.mapAttrs (
              _leaf: source:
                runtimeFiles.sinkEntry (entry
                  // {
                    content = {inherit source;};
                    recursive = false;
                  })
            ) (formats.walk path entry.rendered.source)
          else {${path} = runtimeFiles.sinkEntry (entry // {content = entry.rendered;});}
      )
      (bucket "symlink");

    owned = {
      activation = mergeBundles ["home" "activation"];
      enterTest = lib.concatStringsSep "\n" (lib.filter (body: body != "") (map (bundle: bundle.enterTest or "") bundles));
      plans = mergeBundles ["ai" runtime "_ownPlans"];
      tasks = mergeBundles ["tasks"];
    };

    # Everything the layer can check about a delivery description, said where
    # the option path is still known. Silently dropping a file is the one
    # outcome that looks like success.
    assertions =
      lib.mapAttrsToList (path: entry: {
        assertion = lib.elem entry.method routed;
        message = ''
          ai.${runtime}.files."${path}" resolves to method `${entry.method}`,
          which the delivery layer does not route yet. Until it does, state
          `method = "symlink"` or deliver the file from the factory.
        '';
      })
      resolved
      ++ lib.mapAttrsToList (path: entry: {
        assertion = !(lib.elem entry.method owningMethods) || (entry.entry != null && entry.ledger != null);
        message = ''
          ai.${runtime}.files."${path}" is delivered as `${entry.method}`, so it
          needs the writer that materializes it and the ledger that claims it:
          set `entry` and `ledger`, and declare both under
          ai.${runtime}.activation.
        '';
      }) (lib.filterAttrs (_path: entry: lib.elem entry.method owningMethods) resolved)
      ++ map (entry: {
        assertion = cfg.activation ? ${entry.entry} && cfg.activation.${entry.entry}.ledgers ? ${entry.ledger};
        message = ''
          ai.${runtime}.files."${entry.path}" claims ledger `${entry.ledger}` of
          writer `${entry.entry}`, which does not declare it. A ledger lives on
          the writer so that a ledger no file claims still releases its path.
        '';
      }) (lib.filter (entry: cfg.activation ? ${entry.entry}) owningEntries)
      ++ map (entry: {
        assertion = entry.method != "shared" || formats.table.${entry.format}.sharedOk;
        message = ''
          ai.${runtime}.files."${entry.path}" is delivered as `shared`, which
          owns declared leaves INSIDE a document the harness also writes.
          Format `${entry.format}` names no container leaves can be owned in,
          so this file is whole-file or nothing.
        '';
      })
      owningEntries
      ++ lib.mapAttrsToList (name: writer: {
        assertion = writer.command != null || writer.ledgers != {};
        message = ''
          ai.${runtime}.activation.${name} declares neither a `command` nor a
          ledger, so it materializes nothing. Give it the ledger it owns, or a
          command if its work owns no files.
        '';
      })
      cfg.activation
      ++ lib.concatMap (
        entry:
          map (ledger: {
            assertion = lib.hasPrefix "${ledger.path}/" entry.path;
            message = ''
              ai.${runtime}.files."${entry.path}" claims a directory ledger
              whose container is `${ledger.path}`. The reconciler writes each
              unit INSIDE its container, so the file would land somewhere other
              than the path it is declared at.
            '';
          }) (lib.filter (ledger: ledger.codec == "dir") (
            lib.optional (cfg.activation ? ${entry.entry} && cfg.activation.${entry.entry}.ledgers ? ${entry.ledger})
            cfg.activation.${entry.entry}.ledgers.${entry.ledger}
          ))
      )
      owningEntries;
  }
