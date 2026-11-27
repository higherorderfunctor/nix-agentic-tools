# cspell:ignore urandom
# Check refusals for leaks and their specific diagnostic: tryEval drops it, so a
# dummy-store evaluator reads each one. The sentinel exists only at build time
# and reaches the probe as an argument, so neither the probe's source nor any
# store path holds it, and its presence in the output can only be a leak.
{
  lib,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../config/shell-strict.nix
      ../../lib/open-keys
      ../../lib/redact
      ../../lib/strict-shell-application.nix
    ];
  };
  # Good and bad inputs go through the same entry point. Put the sentinel
  # where a user might put a secret so the refusal must not echo it.
  rejects = read: valid: invalid: message: {
    inherit message;
    accepted = "(${read}) (${valid})";
    refused = "(${read}) (${invalid})";
  };
  sealed = read: valid: invalid: rejects read valid invalid "refused a value that is not a redact reference";
  assignToken = ''assign "TOKEN"'';
  deliveredOnlyByService = "delivered only by an ai.services launcher";
  environment = "evaluate redact.types.environment";
  fileRefusal = sealed "redact.file" ''"/run/secrets/''${sentinel}"'';
  maybeStr = "evaluate (redact.types.maybeRedacted lib.types.str)";
  notIdentifier = "the variable name is not a shell identifier";
  redacted = "evaluate redact.types.redacted";
  secretFile = "evaluate redact.types.secretFile";
  refusals = {
    # References and concat constructors.
    commandRelative = sealed "redact.command" ''"/bin/''${sentinel}"'' "sentinel";
    concatLiteral = sealed "redact.concat" ''[ "Bearer " ref ]'' ''[ "Bearer " sentinel ]'';
    concatNested = sealed "redact.concat" ''[ "a" ref ]'' ''[ "a" (redact.concat [ ref sentinel ]) ]'';
    fileDot = fileRefusal ''"/run/./secrets/''${sentinel}"'';
    fileEmptySegment = fileRefusal ''"/''${builtins.storeDir}/aaaa-source/''${sentinel}"'';
    fileRelative = fileRefusal ''"run/secrets/''${sentinel}"'';
    fileStore = fileRefusal ''"''${builtins.storeDir}/aaaa-source/''${sentinel}"'';
    fileTraversal = fileRefusal ''"/run/..''${builtins.storeDir}/aaaa-source/''${sentinel}"'';

    # Option types, forced through the module merge rather than the constructors.
    environmentDashed = rejects environment ''{ GOOD_NAME = sentinel; }'' ''{ "BAD-NAME" = sentinel; }'' notIdentifier;
    environmentInvalidNull = rejects environment ''{ GOOD_NAME = null; }'' ''{ "BAD-NAME" = null; }'' notIdentifier;
    environmentLeadingDigit = rejects environment ''{ X1 = sentinel; }'' ''{ "1X" = sentinel; }'' notIdentifier;
    environmentLiteral = sealed environment "{ API_TOKEN = ref; }" "{ API_TOKEN = sentinel; }";
    environmentNullConflict =
      rejects environment
      "lib.mkMerge [ { API_TOKEN = null; } { API_TOKEN = null; } ]"
      "lib.mkMerge [ { API_TOKEN = null; } { API_TOKEN = sentinel; } ]"
      "defined both null and not null";
    maybeAttrsReservedKey = sealed "evaluate (redact.types.maybeRedacted (lib.types.attrsOf lib.types.str))" "{ public = sentinel; }" "{ _redact = sentinel; }";
    maybeIntWrongType = sealed "evaluate (redact.types.maybeRedacted lib.types.int)" "1" "sentinel";
    maybeStrInvalidConcat = sealed maybeStr "sentinel" "{ _redact.concat = [ sentinel ]; }";
    maybeStrInvalidReference = sealed maybeStr "sentinel" "{ _redact.file = sentinel; }";
    maybeStrWrongType = sealed maybeStr "sentinel" "1";
    orSecretFileMixedDefinitions =
      rejects "evaluate (redact.types.orSecretFile redact.types.redacted)"
      "lib.mkMerge [ ref ref ]"
      "lib.mkMerge [ ref (asFile ref) ]"
      "defined both as a redact.types.secretFile value and as another value";
    redactedInvalidConcat = sealed redacted "{ _redact.concat = [ ref ]; }" "{ _redact.concat = [ sentinel ]; }";
    redactedLiteral = sealed redacted "ref" "sentinel";
    redactedRelative = sealed redacted "ref" "{ _redact.file = sentinel; }";
    # A secret file reaching a value consumer says where it can go instead.
    redactedSecretFile = rejects redacted "ref" "asFile ref" deliveredOnlyByService;
    redactedTwoSources = sealed redacted "{ _redact.file = \"/a\"; }" ''{ _redact = { command = "/''${sentinel}"; file = "/a"; }; }'';
    secretFileLiteral = sealed secretFile "ref" "sentinel";
    secretFileStore = sealed secretFile "ref" ''{ _redact.file = "''${builtins.storeDir}/aaaa-source/''${sentinel}"; }'';
    secretFileTaggedLiteral = sealed secretFile "asFile ref" "asFile sentinel";

    # assign rejects inputs before emitting any launch shell.
    assignInvalidName = rejects "name: assign name sentinel" ''"TOKEN"'' ''"BAD-NAME"'' notIdentifier;
    assignInvalidReference = sealed assignToken "ref" "{ _redact.file = sentinel; }";
    assignSecretFile = rejects assignToken "ref" "asFile ref" deliveredOnlyByService;
    assignWrongType = sealed assignToken "sentinel" "1";
  };
  probeRows =
    lib.mapAttrsToList (name: refusal: ''
      ${name} = { accepted = ${refusal.accepted}; refused = ${refusal.refused}; };
    '')
    refusals;
  probe = pkgs.writeText "redact-messages.nix" ''
    { sentinel, row, input }:
    let
      lib = import ${pkgs.path}/lib;
      redact = import ${source}/lib/redact { inherit lib; };
      ref = redact.file "/''${sentinel}";
      asFile = value: { _redact.asFile = value; };
      # This evaluator does not build or run the reader. Only its executable
      # path is needed to force a valid assignment's emitted shell.
      assign = variable: value: redact.assign {
        inherit value variable;
        option = "test.token";
        pkgs.writeShellApplication = _: {
          type = "derivation";
          outPath = "/redact-reader-probe";
          meta.mainProgram = "redact-read";
        };
      };
      evaluate = type: value:
        (lib.evalModules {
          modules = [
            { options.value = lib.mkOption { inherit type; }; }
            { config.value = value; }
          ];
        }).config.value;
      cases = {
        ${lib.concatLines probeRows}
      };
    in
      builtins.deepSeq cases.''${row}.''${input} true
  '';
in {
  checks.redact-messages = mkLintedCheck "redact-messages" {
    runtimeInputs = [pkgs.nix];
    text = ''
      export HOME="$TMPDIR"
      sentinel="redact-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      evaluate() {
        nix-instantiate --eval --strict --store dummy:// ${probe} \
          --argstr sentinel "$sentinel" --argstr row "$1" --argstr input "$2" >probe.out 2>probe.err
      }
      refuses() {
        evaluate "$1" accepted || {
          printf 'FAIL: %s rejected its control\n' "$1" >&2
          exit 1
        }
        if evaluate "$1" refused; then
          printf 'FAIL: %s was accepted\n' "$1" >&2
          exit 1
        fi
        if grep -qF "$sentinel" probe.out probe.err; then
          printf 'FAIL: %s printed the refused value\n' "$1" >&2
          exit 1
        fi
        grep -qF "$2" probe.err || {
          printf 'FAIL: %s failed without its refusal:\n' "$1" >&2
          cat probe.err >&2
          exit 1
        }
      }
      ${lib.concatLines (lib.mapAttrsToList (name: refusal: "refuses ${lib.escapeShellArgs [name refusal.message]}") refusals)}
    '';
  };
}
