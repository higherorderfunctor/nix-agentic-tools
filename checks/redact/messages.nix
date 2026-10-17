# cspell:ignore urandom
# Every refusal is leak-safe: tryEval cannot see a throw's message, so a
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
      ../../lib/open-keys
      ../../lib/redact
    ];
  };
  # Each value receives the sentinel where a consumer would put a secret, and
  # each refusal must show its message.
  sealed = expression: {
    inherit expression;
    message = "refused a value that is not a redact reference";
  };
  refusals = {
    command = sealed "redact.command sentinel";
    concat = sealed "redact.concat [ sentinel ]";
    environment = sealed "evaluate redact.types.environment { API_TOKEN = sentinel; }";
    environmentNull = {
      expression = "evaluate redact.types.environment (lib.mkMerge [ { API_TOKEN = null; } { API_TOKEN = sentinel; } ])";
      message = "defined both null and not null";
    };
    file = sealed "redact.file sentinel";
    marker = sealed "evaluate (redact.types.maybeRedacted lib.types.str) { _redact.concat = [ sentinel ]; }";
    maybeRedacted = sealed "evaluate (redact.types.maybeRedacted lib.types.int) sentinel";
    redacted = sealed "evaluate redact.types.redacted sentinel";
  };
  probe = pkgs.writeText "redact-messages.nix" ''
    { sentinel, case }:
    let
      lib = import ${pkgs.path}/lib;
      redact = import ${source}/lib/redact { inherit lib; };
      evaluate = type: value:
        (lib.evalModules {
          modules = [
            { options.value = lib.mkOption { inherit type; }; }
            { config.value = value; }
          ];
        }).config.value;
      cases = {
        ${lib.concatStrings (lib.mapAttrsToList (name: refusal: "${name} = ${refusal.expression};\n") refusals)}
        control = evaluate redact.types.redacted (redact.file "/''${sentinel}");
      };
    in
      builtins.deepSeq cases.''${case} true
  '';
in {
  checks.redact-messages = mkLintedCheck "redact-messages" {
    runtimeInputs = [pkgs.nix];
    text = ''
      export HOME="$TMPDIR"
      sentinel="redact-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      evaluate() {
        nix-instantiate --eval --strict --store dummy:// ${probe} \
          --argstr sentinel "$sentinel" --argstr case "$1" >probe.out 2>probe.err
      }
      refuses() {
        if evaluate "$1"; then
          printf 'FAIL: %s was accepted\n' "$1" >&2
          exit 1
        fi
        grep -qF "$2" probe.err || {
          printf 'FAIL: %s failed without its refusal:\n' "$1" >&2
          cat probe.err >&2
          exit 1
        }
        if grep -qF "$sentinel" probe.out probe.err; then
          printf 'FAIL: %s printed the refused value\n' "$1" >&2
          exit 1
        fi
      }
      # Positive control: the probe evaluates when the value is a reference.
      evaluate control
      ${lib.concatLines (lib.mapAttrsToList (name: refusal: "refuses ${lib.escapeShellArgs [name refusal.message]}") refusals)}
    '';
  };
}
