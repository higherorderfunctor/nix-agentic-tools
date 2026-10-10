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
  # An owner's `extracted/` directory, as the string of a store path so
  # mkDriftCheck can append `/<system>.json` as it does to `./extracted`.
  directory = raws: "${pkgs.linkFarm "committed" (lib.mapAttrsToList (system: value: {
      name = "${system}.json";
      path = raw system value;
    })
    raws)}";
  sidecar = "packages/fake/extracted";
  cases = {
    per-system-drift = {
      args = {
        committed = directory {${host} = {a = 1;};};
        extracted.${host} = raw "extracted" {a = 2;};
        inherit sidecar;
      };
      fails = ["${sidecar}/${host}.json"];
    };
    per-system-skips-foreign = {
      args = {
        committed = directory {
          ${host} = {a = 1;};
          ${other} = {a = 0;};
        };
        extracted = {
          ${host} = raw "extracted" {a = 1;};
          ${other} = foreign;
        };
        inherit sidecar;
      };
    };
    single-drift = {
      args = {
        committed = raw "committed" {a = 1;};
        extracted = raw "extracted" {a = 2;};
        sidecar = "packages/fake/extracted.json";
      };
      fails = ["packages/fake/extracted.json"];
    };
    single-match = {
      args = {
        committed = raw "committed" {a = 1;};
        extracted = raw "extracted" {a = 1;};
        sidecar = "packages/fake/extracted.json";
      };
    };
    # Every drifted system is named before the check fails.
    static-names-both = {
      args = {
        committed = directory {
          ${host} = {a = 0;};
          ${other} = {a = 0;};
        };
        extracted = {
          ${host} = raw "fresh-host" {a = 1;};
          ${other} = raw "fresh-other" {a = 2;};
        };
        inherit sidecar;
      };
      fails = ["${sidecar}/${host}.json" "${sidecar}/${other}.json"];
    };
    # A static extractor supplies every system from this host; only the
    # drifted one is named.
    static-names-drifted = {
      args = {
        committed = directory {
          ${host} = {a = 1;};
          ${other} = {a = 0;};
        };
        extracted = {
          ${host} = raw "extracted" {a = 1;};
          ${other} = raw "fresh" {a = 2;};
        };
        inherit sidecar;
      };
      fails = ["${sidecar}/${other}.json"];
    };
  };
  script = case: (mkDriftCheck (case.args // {name = "fake";})).fake-extracted.buildCommand;
  run = label: case: ''
    mkdir "$TMPDIR/${label}"
    if (cd "$TMPDIR/${label}" && out="$TMPDIR/${label}/out" bash ${pkgs.writeText "${label}.sh" (script case)}) 2> "$TMPDIR/${label}/err"; then
      ${
      if case ? fails
      then ''echo "FAIL: ${label} passed; it must fail naming ${toString case.fails}" >&2; exit 1''
      else ":"
    }
    else
      ${
      if case ? fails
      then
        lib.concatMapStrings (path: ''
          grep -qF 'sidecar (${path})' "$TMPDIR/${label}/err" || { echo "FAIL: ${label} message does not name ${path}:" >&2; cat "$TMPDIR/${label}/err" >&2; exit 1; }
        '')
        case.fails
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
