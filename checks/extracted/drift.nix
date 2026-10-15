# mkDriftCheck with per-system inputs. Each case runs the generated drift
# script outside its derivation, so a case that must fail can, and asserts
# the exit status and the message the operator reads. A case with
# `regenerate` reads the regenerate script's text for the fresh raws it must
# carry (`names`) and must not (`omits`).
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) mkDriftCheck;
  runner = import ./runner.nix {inherit lib;};
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
  # The committed file, written at evaluation time so reading it is no
  # import from derivation.
  committed = merged: builtins.toFile "extracted.json" (builtins.toJSON merged);
  sidecar = "packages/fake/extracted/extracted.json";
  fresh = {
    drifted = raw "fresh-drifted" {a = 2;};
    matching = raw "fresh-matching" {a = 1;};
  };
  cases = {
    # A fork is compared through the host's projection, not the stored tree.
    forked-match = {
      args = {
        committed = committed {
          a.__platforms = {
            ${host} = 1;
            ${other} = 2;
          };
        };
        extracted.${host} = fresh.matching;
      };
      regenerate.names = [fresh.matching];
    };
    per-system-drift = {
      args = {
        committed = committed {a = 1;};
        extracted.${host} = fresh.drifted;
      };
      fails = [host];
      omits = [other];
    };
    per-system-skips-foreign = {
      args = {
        committed = committed {a = 1;};
        extracted = {
          ${host} = fresh.matching;
          ${other} = foreign;
        };
      };
      regenerate = {
        names = [fresh.matching];
        omits = [foreign];
      };
    };
    # Every drifted system is named before the check fails.
    static-names-both = {
      args = {
        committed = committed {a = 0;};
        extracted = {
          ${host} = fresh.matching;
          ${other} = fresh.drifted;
        };
      };
      fails = [host other];
    };
    # A static extractor supplies every system from this host; only the
    # drifted one is named, the matching one is not.
    static-names-drifted = {
      args = {
        committed = committed {a = 1;};
        extracted = {
          ${host} = fresh.matching;
          ${other} = fresh.drifted;
        };
      };
      fails = [other];
      omits = [host];
      regenerate.names = [fresh.matching fresh.drifted];
    };
  };
  check = case: (mkDriftCheck (case.args // {inherit sidecar name;})).fake-extracted;
  name = "fake";
  script = case: (check case).buildCommand;
  # Unmet `regenerate` expectations, each naming its case.
  regenerating = lib.concatLists (lib.mapAttrsToList (label: case: let
    # The store paths only: matching needs no build of what they name.
    text = builtins.unsafeDiscardStringContext (check case).regenerate.text;
    carries = path: lib.hasInfix (builtins.unsafeDiscardStringContext "${path}") text;
  in
    map (path: "${label} does not carry ${path}") (builtins.filter (path: !carries path) case.regenerate.names or [])
    ++ map (path: "${label} carries ${path}") (builtins.filter carries case.regenerate.omits or []))
  (lib.filterAttrs (_: case: case ? regenerate) cases));
  named = system: "the ${system} side of ${sidecar}";
  run = label: case:
    runner {
      inherit label;
      command = ''(mkdir "$TMPDIR/${label}" && cd "$TMPDIR/${label}" && out="$TMPDIR/${label}/out" bash ${pkgs.writeText "${label}.sh" (script case)})'';
      names = map named case.fails or [];
      omits = map named case.omits or [];
    };
in {
  checks.extracted-drift = assert lib.assertMsg (regenerating == []) (lib.concatStringsSep "; " regenerating);
    pkgs.runCommand "extracted-drift" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.concatStrings (lib.mapAttrsToList run cases)}
      echo "ok — ${toString (builtins.length (builtins.attrNames cases))} drift cases" > "$out"
    '';
}
