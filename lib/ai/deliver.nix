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
  aiTypes = import ./types.nix {inherit lib;};
  deliveryMethod = import ./deliveryMethod.nix {inherit lib;};
  formats = import ./formats.nix {inherit lib pkgs;};
  helpers = import ./hm-helpers.nix {inherit lib;};
  runtimeFiles = import ./runtime-files.nix {inherit lib;};

  # The methods this layer delivers today. The assertion below is an
  # EXHAUSTIVENESS guard: a method added to `deliveryMethod.methods` without a
  # bucket here would otherwise resolve for a file that nothing then writes.
  owningMethods = ["copy-ro" "shared"];
  routed = ["copy-ro" "shared" "symlink" "upstream"];

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

  # The roots an `upstream` sink may land under, per backend. This is not a
  # policy about which options deserve a sink — it is the module system's
  # constraint, measured on this file: a fragment whose TOP-LEVEL attribute
  # name comes from a configuration value forces `ai.<runtime>.files` while
  # the module system is still collecting the definitions that option is made
  # of, and evaluation dies with `error: infinite recursion encountered`. An
  # adapter can therefore only host a sink under a root it states as a
  # LITERAL, and these are the roots each adapter already writes.
  #
  # It is also why the list is as SHORT as it is. Hosting a root makes that
  # root's sub-names derived, so anything read under it forces the whole file
  # map: adding `home` made `config.home.packages` force every runtime's
  # entries, and `checks/ai-context` caught it — a `rulesDir` that only has to
  # be valid when something reads the rules stopped being lazy. These two
  # roots are the ones a delegated surface actually lands in.
  upstreamRoots = {
    devenv = ["files"];
    hm = ["programs"];
  };
in
  {
    backend,
    cfg,
    config,
    options,
    runtime,
  }: let
    edges = tokens: names: lib.filter (node: node != null) (map (token: tokens.${backend}.${token} or null) names);

    # A writer's entry name may differ per backend, and both spellings are
    # literals a consumer orders against. A backend-keyed name that omits THIS
    # backend is a declaration error: `option` names it, because the bare
    # selection answers `attribute 'devenv' missing` and names nothing.
    nameFor = option: value:
      if builtins.isString value
      then value
      else
        value.${
          backend
        }
        or (throw ''
          ai.${runtime}.activation.${option} states an entry name per backend
          but none for `${backend}`. Give it one, or state a single string
          both backends use.
        '');

    # Disabled text-source records are not files; everything below sees live
    # entries only. `run` and `value` are independently live alternatives.
    live = lib.filterAttrs (_path: entry:
      entry.content.enable || entry.content.run != null || entry.content.value != null)
    cfg.files;

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
          if entry.content.value != null
          then
            formats.render {
              inherit (entry) format;
              inherit path;
              inherit (entry.content) value;
            }
          else if entry.content.run != null
          then {inherit (entry.content) run;}
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
        if aiTypes.textSourceUsesSource entry.rendered
        then {store = entry.rendered.source;}
        else if (entry.rendered.run or null) != null
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
                if (entry.rendered.run or null) != null
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
    ownsDirectory = writer: lib.any (ledger: ledger.codec == "dir") (lib.attrValues writer.ledgers);
    # A `dir` ledger is two Home Manager entries, because a real file this
    # writer owns must be gone before `checkLinkTargets` while a new one may
    # only appear after `linkGeneration`. `own` refuses the bundle without the
    # second name, but its message names a TARGET; this one names the option
    # that is missing, and throws for the same reason `own` does — a bundle
    # with one phase silently keeps last generation's files.
    entryNamesFor = name: writer:
      if backend == "hm" && ownsDirectory writer && writer.pruneEntry == null
      then
        throw ''
          ai.${runtime}.activation.${name} owns a `dir` ledger, so Home Manager
          needs `pruneEntry` as well: the phase that deletes a real file runs
          before `checkLinkTargets`, and the phase that writes one after
          `linkGeneration`.
        ''
      else
        {write = nameFor "${name}.entry" writer.entry;}
        // lib.optionalAttrs (backend == "hm" && writer.pruneEntry != null) {
          prune = nameFor "${name}.pruneEntry" writer.pruneEntry;
        };
    # Every (writer, ledger, claimants) triple, for the checks that are about a
    # LEDGER rather than about one file.
    ledgerClaims = lib.concatLists (lib.mapAttrsToList (
        name: writer:
          lib.mapAttrsToList (ledger: declaration: {
            inherit declaration ledger name;
            claiming = lib.filter (entry: entry.ledger == ledger) (claimsOf name);
          })
          writer.ledgers
      )
      owningWriters);
    # The ledger an owning entry claims, as a LIST so that an entry naming one
    # the writer never declared produces that single assertion and no
    # attribute-missing error behind it.
    declaredLedger = entry:
      lib.optional (cfg.activation ? ${entry.entry} && cfg.activation.${entry.entry}.ledgers ? ${entry.ledger})
      cfg.activation.${entry.entry}.ledgers.${entry.ledger};
    repeated = names: lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
    bundles =
      lib.mapAttrsToList (
        name: writer:
          helpers.mkOwnBundle {
            inherit backend pkgs runtime;
            after = bundleAfterEdges writer;
            declared =
              lib.listToAttrs (map (entry: lib.nameValuePair entry.path entry.content.value)
                (lib.filter (entry: entry.method == "shared" && entry.content.value != null) (claimsOf name)));
            entryNames = entryNamesFor name writer;
            hasFiles = (config.files or {}) != {};
            python = formats.pythonFor writer.ledgers;
            targets = targetsFor name writer;
          }
      )
      owningWriters;
    # An upstream entry hands its content to another module's option. The
    # VALUE travels, never the rendered bytes: the option that owns the file
    # owns how it is written, which is the whole point of delegating it.
    sunk = lib.attrValues (bucket "upstream");
    upstreamValue = entry:
      if entry.content.value != null
      then entry.content.value
      else if aiTypes.textSourceUsesSource entry.content
      then entry.content.source
      else entry.content.text;
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

    # Writers that own no files at all: their whole product is the body. One
    # entry each, keyed by the literal name that backend uses — the only part
    # an adapter states is the TAIL, the activation entry or task record the
    # backend takes, because that is the only part that differs.
    commandEntries = lower:
      lib.mapAttrs' (
        name: writer: lib.nameValuePair (nameFor "${name}.entry" writer.entry) (lower writer)
      )
      (lib.filterAttrs (_name: writer: writer.command != null) cfg.activation);

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

    # ── upstream: the bytes are another module's to write ────────────────
    #
    # The content is handed to the option `sink` names and no file is
    # delivered for it here. That is how a surface another module owns — an
    # upstream `programs.<cli>` option, or a document a backend deep-merges —
    # stays IN this runtime's delivery description instead of vanishing from
    # it, with the same facts, enable gate and override boundary as a file this
    # layer writes itself.
    #
    # Handed to the adapter one ROOT at a time, because that root is the one
    # attribute name the adapter has to state as a literal; see the
    # `upstreamRoots` table above for what happens otherwise.
    upstreamRoots = upstreamRoots.${backend};
    upstreamUnder = root:
      lib.foldl' lib.recursiveUpdate {}
      (map (entry: lib.setAttrByPath (lib.tail entry.sink) (upstreamValue entry))
        (lib.filter (entry: entry.sink != [] && lib.head entry.sink == root) sunk));

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
      # `recursive` delivers the LEAVES of a directory source. Home Manager
      # takes the flag for anything and links a single file under a directory
      # name; only the devenv walk refuses it, and then only on that backend.
      ++ lib.mapAttrsToList (path: entry: {
        assertion =
          !entry.recursive
          || (aiTypes.textSourceUsesSource entry.content && (builtins.readFileType entry.content.source) == "directory");
        message = ''
          ai.${runtime}.files."${path}" sets `recursive`, which delivers the
          leaves of a DIRECTORY, but its content is ${
            if aiTypes.textSourceUsesSource entry.content
            then "a single file"
            else "not a `source` at all"
          }. A single
          file is delivered by naming its own path.
        '';
      })
      resolved
      # `sink` and `upstream` are one declaration in two fields: a sink with
      # another method is ignored, and an upstream entry without one has
      # nowhere to put its bytes.
      ++ lib.mapAttrsToList (path: entry: {
        assertion = (entry.method == "upstream") == (entry.sink != []);
        message = ''
          ai.${runtime}.files."${path}" ${
            if entry.method == "upstream"
            then "is delivered as `upstream`, so it needs the `sink` that names the option owning it"
            else "names a `sink`, which only `method = \"upstream\"` reads"
          }.
          An upstream file is handed to another module's option; nothing in the
          delivery layer writes it.
        '';
      })
      resolved
      ++ map (entry: {
        assertion =
          lib.elem (lib.head entry.sink) upstreamRoots.${backend}
          && options ? ${lib.head entry.sink};
        message = ''
          ai.${runtime}.files."${entry.path}" hands its content to
          `${lib.concatStringsSep "." entry.sink}`, whose root the ${backend}
          adapter does not host. It writes upstream sinks under
          ${lib.concatMapStringsSep " and " (root: "`${root}`") upstreamRoots.${backend}}
          only, because an attribute name it cannot state as a literal forces
          ai.${runtime}.files while that option is still collecting its own
          definitions.
        '';
      }) (lib.filter (entry: entry.sink != []) sunk)
      ++ lib.mapAttrsToList (path: entry: {
        assertion = entry.content.run == null || lib.elem entry.method owningMethods;
        message = ''
          ai.${runtime}.files."${path}" carries `content.run`, a body that
          WRITES the file, but resolves to method `${entry.method}`. Only a
          copy this runtime owns or a document it reconciles has a write step
          to run it in.
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
      # The writer FIRST, then the ledger on it. Checking only the ledger read
      # the writer out of `cfg.activation` and had to filter to the writers
      # that exist, so a file naming a writer nobody declares was dropped from
      # the check as well as from the generation.
      ++ map (entry: {
        assertion = cfg.activation ? ${entry.entry};
        message = ''
          ai.${runtime}.files."${entry.path}" is materialized by writer
          `${entry.entry}`, which ai.${runtime}.activation does not declare.
          Nothing writes this file, and nothing retracts it either.
        '';
      })
      owningEntries
      ++ map (entry: {
        assertion = cfg.activation.${entry.entry}.ledgers ? ${entry.ledger};
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
      # A `dir` ledger addresses its units by BASENAME, so the container has to
      # be the file's own directory: `hasPrefix` accepted a nested path and the
      # unit then landed directly in the container, one level up from where it
      # was declared.
      ++ lib.concatMap (
        entry:
          map (ledger: {
            assertion = dirOf entry.path == ledger.path;
            message = ''
              ai.${runtime}.files."${entry.path}" claims a directory ledger
              whose container is `${ledger.path}`. The reconciler addresses
              each unit by its basename INSIDE that container, so this file
              would land at `${ledger.path}/${baseNameOf entry.path}` rather
              than at the path it is declared at.
            '';
          }) (lib.filter (ledger: ledger.codec == "dir") (declaredLedger entry))
      )
      owningEntries
      # A document ledger owns LEAVES of a parsed container, so its claimant
      # has to carry something with leaves. `content.text` under one reached
      # `entry.content.value` and died with `attribute 'value' missing`.
      ++ lib.concatMap (
        entry:
          map (ledger: {
            assertion = entry.content.value != null || entry.content.run != null;
            message = ''
              ai.${runtime}.files."${entry.path}" claims ledger
              `${entry.ledger}`, whose codec is `${ledger.codec}`: a document
              whose declared leaves this runtime owns. State those leaves as
              `content.value`, or a body that writes the whole file as
              `content.run` — literal bytes name no leaves to own.
            '';
          }) (lib.filter (ledger: ledger.codec != "dir") (declaredLedger entry))
      )
      owningEntries
      # `listToAttrs` keeps the LAST pair for a repeated name, so two claimants
      # at one unit address silently become one unit — and the file that lost
      # is neither written nor reported.
      ++ map (claim: let
        addresses = map (entry: baseNameOf entry.path) claim.claiming;
      in {
        assertion = repeated addresses == [];
        message = ''
          ai.${runtime}.activation.${claim.name}.ledgers."${claim.ledger}" is
          claimed by two files at one unit address:
          ${lib.concatStringsSep ", " (repeated addresses)}. A directory
          ledger addresses its units by basename, so only one of them would be
          written.
        '';
      }) (lib.filter (claim: claim.declaration.codec == "dir") ledgerClaims)
      # One document, one claimant. A second one was dropped by `lib.head`,
      # which picked whichever the attribute order happened to put first.
      ++ map (claim: {
        assertion = lib.length claim.claiming < 2;
        message = ''
          ai.${runtime}.activation.${claim.name}.ledgers."${claim.ledger}" is a
          document ledger claimed by
          ${lib.concatStringsSep ", " (map (entry: ''"${entry.path}"'') claim.claiming)}.
          A document is reconciled as ONE declaration; claiming it twice writes
          one of them and silently discards the other.
        '';
      }) (lib.filter (claim: claim.declaration.codec != "dir") ledgerClaims)
      # `before` reaches a bundle through nothing: `own` positions itself, and
      # the router hands it `after` only. The default happens to be exactly
      # what `own` does — `devenv:enterShell` plus the conditional
      # `devenv:files` on devenv, and the prune phase before
      # `checkLinkTargets` on Home Manager — so anything else is a silent
      # no-op, which is the one outcome worth failing for.
      ++ lib.mapAttrsToList (name: writer: {
        assertion = writer.before == ["shell"];
        message = ''
          ai.${runtime}.activation.${name} owns ledgers and states
          `before = ${builtins.toJSON writer.before}`. A reconciler bundle
          positions itself: it runs before `devenv:enterShell` (plus the
          conditional `devenv:files`) on devenv, and its prune phase before
          `checkLinkTargets` on Home Manager. `before` is read for a `command`
          writer only, so this value would be ignored.
        '';
      })
      owningWriters
      ++ lib.mapAttrsToList (name: writer: {
        assertion = writer.command != null || writer.ledgers != {};
        message = ''
          ai.${runtime}.activation.${name} declares neither a `command` nor a
          ledger, so it materializes nothing. Give it the ledger it owns, or a
          command if its work owns no files.
        '';
      })
      cfg.activation
      # The two are not layers of one writer: the router builds a reconciler
      # bundle for a writer with ledgers and an activation entry for a writer
      # with a command, and a writer with both lowered to the command alone —
      # every ledger it declared, and every file claiming one, vanished.
      ++ lib.mapAttrsToList (name: writer: {
        assertion = writer.command == null || writer.ledgers == {};
        message = ''
          ai.${runtime}.activation.${name} declares both a `command` and
          `ledgers`. A writer is one or the other: the command is for work
          that owns no files, and the ledgers are what the reconciler
          materializes. Split it into two writers.
        '';
      })
      cfg.activation;
  }
