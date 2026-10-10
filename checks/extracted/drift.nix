# mkDriftCheck in both input shapes. Each case runs the generated drift
# script outside its derivation, so a case that must fail can, and asserts
# the exit status and the message the operator reads.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) mkDriftCheck;
  host = pkgs.stdenv.hostPlatform.system;
  # A system this host cannot build for: a host-run extractor's derivation.
  other = lib.findFirst (system: system != host) null (import ../../config/systems.nix);
  raw = name: value: pkgs.writeText "${name}.json" (builtins.toJSON value);
  # Never built: a case that compares it would fail the fixture's own build.
  foreign = derivation {
    builder = "/bin/sh";
    name = "foreign-extracted";
    system = other;
  };
  cases = {
    per-system-drift = {
      args = {
        committed.${host} = raw "committed" {a = 1;};
        extracted.${host} = raw "extracted" {a = 2;};
        sidecar.${host} = "packages/fake/extracted/${host}.json";
      };
      fails = "packages/fake/extracted/${host}.json";
    };
    per-system-skips-foreign = {
      args = {
        committed = {
          ${host} = raw "committed" {a = 1;};
          ${other} = raw "stale" {a = 0;};
        };
        extracted = {
          ${host} = raw "extracted" {a = 1;};
          ${other} = foreign;
        };
        sidecar = {
          ${host} = "packages/fake/extracted/${host}.json";
          ${other} = "packages/fake/extracted/${other}.json";
        };
      };
    };
    single-drift = {
      args = {
        committed = raw "committed" {a = 1;};
        extracted = raw "extracted" {a = 2;};
        sidecar = "packages/fake/extracted.json";
      };
      fails = "packages/fake/extracted.json";
    };
    single-match = {
      args = {
        committed = raw "committed" {a = 1;};
        extracted = raw "extracted" {a = 1;};
        sidecar = "packages/fake/extracted.json";
      };
    };
    # A static extractor supplies every system from this host; only the
    # drifted one is named.
    static-names-drifted = {
      args = {
        committed = {
          ${host} = raw "committed" {a = 1;};
          ${other} = raw "stale" {a = 0;};
        };
        extracted = {
          ${host} = raw "extracted" {a = 1;};
          ${other} = raw "fresh" {a = 2;};
        };
        sidecar = {
          ${host} = "packages/fake/extracted/${host}.json";
          ${other} = "packages/fake/extracted/${other}.json";
        };
      };
      fails = "packages/fake/extracted/${other}.json";
    };
  };
  script = case: (mkDriftCheck (case.args // {name = "fake";})).fake-extracted.buildCommand;
  run = label: case: ''
    mkdir "$TMPDIR/${label}"
    if (cd "$TMPDIR/${label}" && out="$TMPDIR/${label}/out" bash ${pkgs.writeText "${label}.sh" (script case)}) 2> "$TMPDIR/${label}/err"; then
      ${
      if case ? fails
      then ''echo "FAIL: ${label} passed; it must fail naming ${case.fails}" >&2; exit 1''
      else ":"
    }
    else
      ${
      if case ? fails
      then ''grep -qF 'sidecar (${case.fails})' "$TMPDIR/${label}/err" || { echo "FAIL: ${label} message does not name ${case.fails}:" >&2; cat "$TMPDIR/${label}/err" >&2; exit 1; }''
      else ''echo "FAIL: ${label} failed; it must pass:" >&2; cat "$TMPDIR/${label}/err" >&2; exit 1''
    }
    fi
  '';
in {
  checks.extracted-drift = pkgs.runCommand "extracted-drift" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${lib.concatStrings (lib.mapAttrsToList run cases)}
    echo "ok — ${toString (builtins.length (builtins.attrNames cases))} drift cases" > "$out"
  '';
}
