# Fixtures for lib/extracted/platforms.nix: the committed file's shape
# (dev/fragments/extracted/facts-contract.md, "The committed file"). Each row
# names its visible result or its refused input.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted/platforms.nix) carry merge project;
  systems = import ../../config/systems.nix;
  split = darwin: linux: {
    aarch64-darwin = darwin;
    x86_64-linux = linux;
  };
  fork = darwin: linux: {__platforms = split darwin linux;};
  runner = (import ./runner.nix {inherit lib pkgs;}).nix;
  raws =
    split {
      flags = ["--a" "--b"];
      nested = {
        count = 2;
        same = "x";
      };
      only = "darwin";
      same = {deep = true;};
    } {
      flags = ["--a"];
      nested = {
        count = 1;
        same = "x";
      };
      same = {deep = true;};
    };
  # Independent committed shape: shared nodes stay plain, differing leaves
  # and whole arrays fork, and the Darwin-only key has no Linux leg.
  stored = {
    flags = fork ["--a" "--b"] ["--a"];
    nested = {
      count = fork 2 1;
      same = "x";
    };
    only.__platforms.aarch64-darwin = "darwin";
    same.deep = true;
  };
  committed = {
    count = fork 2 1;
    features = ["old"];
  };
  # Darwin's leg over an unforked node, then Linux's next bump.
  darwinCarried = carry {
    fresh.aarch64-darwin = {
      flags = ["--a" "--c"];
      same = 1;
    };
    merged = {
      flags = ["--a"];
      same = 1;
    };
    inherit systems;
  };
  # A forked command object whose parent the fresh Linux raw removes or retypes.
  commands = {
    cmd = {
      flags = fork ["--a" "--d"] ["--a"];
      help = "h";
    };
  };
  darwinCommand = {
    flags = ["--a" "--d"];
    help = "h";
  };
  darwinAfter = fresh:
    project (carry {
      fresh.x86_64-linux = fresh;
      merged = commands;
      inherit systems;
    }) "aarch64-darwin";

  rows = {
    carry-collapses-agreement =
      carry {
        fresh.x86_64-linux = committed // {count = 2;};
        merged = committed;
        inherit systems;
      }
      == committed // {count = 2;};
    # A Darwin carry leaves Linux as committed and forms a fork.
    carry-darwin-forms-fork =
      darwinCarried
      == {
        flags = fork ["--a" "--c"] ["--a"];
        same = 1;
      }
      && project darwinCarried "x86_64-linux"
      == {
        flags = ["--a"];
        same = 1;
      };
    # When all systems are fresh, the prior tree must not leak into the result.
    carry-every-system-merges =
      carry {
        fresh = raws;
        merged = committed;
        inherit systems;
      }
      == stored;
    # One Linux carry replaces changed unforked data, adds a new key and
    # drops a removed key, without changing the other leg of `count`.
    carry-follows =
      carry {
        fresh.x86_64-linux = {
          added = true;
          count = 1;
          features = ["new" "old"];
        };
        merged = committed // {removed = true;};
        inherit systems;
      }
      == {
        added = true;
        count = fork 2 1;
        features = ["new" "old"];
      };
    # The next Linux carry keeps the Darwin fork but updates shared data.
    carry-linux-keeps-darwin-fork =
      carry {
        fresh.x86_64-linux = {
          flags = ["--a" "--b"];
          same = 2;
        };
        merged = darwinCarried;
        inherit systems;
      }
      == {
        flags = fork ["--a" "--c"] ["--a" "--b"];
        same = 2;
      };
    # A forked parent the base removes or retypes keeps the follower's whole
    # committed value, unforked siblings included.
    carry-removed-parent-kept-whole =
      darwinAfter {other = 1;}
      == {
        cmd = darwinCommand;
        other = 1;
      };
    carry-retyped-parent-kept-whole = darwinAfter {cmd = "gone";} == {cmd = darwinCommand;};
    # Projection uses a fixed committed tree, so a matching bug in `merge`
    # cannot hide a lost leg or a key incorrectly present on Linux.
    project-restores-each-raw = lib.all (system: project stored system == raws.${system}) systems;
    single-raw-unforked = merge {inherit (raws) x86_64-linux;} == raws.x86_64-linux;
  };
  refused = {
    carry-two-fresh = {
      expr = ''        platforms.carry {
                fresh = {aarch64-darwin = {}; x86_64-linux = {};};
                merged = {};
                systems = ["aarch64-darwin" "i686-linux" "x86_64-linux"];
              }'';
      names = ["i686-linux must follow exactly one fresh system, not aarch64-darwin x86_64-linux"];
    };
    merge-sentinel = {
      expr = ''platforms.merge {aarch64-darwin = {}; x86_64-linux.nested.__platforms = 1;}'';
      names = ["`x86_64-linux.nested` holds the reserved key `__platforms` in measured data"];
    };
    merge-sentinel-in-list = {
      expr = ''platforms.merge {x86_64-linux.a = [{__platforms = 1;}];}'';
      names = ["`x86_64-linux.a[]` holds the reserved key `__platforms` in measured data"];
    };
    project-missing-root = {
      expr = ''platforms.project {__platforms.x86_64-linux = {};} "aarch64-darwin"'';
      names = ["the committed tree has no aarch64-darwin side"];
    };
    project-mixed-fork = {
      expr = ''platforms.project {a = {__platforms.x86_64-linux = 1; b = 2;};} "x86_64-linux"'';
      names = ["`x86_64-linux.a` mixes `__platforms` with other keys"];
    };
    project-nested-sentinel = {
      expr = ''platforms.project {a.__platforms.x86_64-linux.__platforms = 1;} "x86_64-linux"'';
      names = ["`x86_64-linux.a` holds the reserved key `__platforms` in measured data"];
    };
  };
  runRefusal = label: case:
    runner {
      inherit label;
      inherit (case) names;
      expr = ''let platforms = import ${../../lib/extracted/platforms.nix}; in ${case.expr}'';
    };
in {
  checks.extracted-platforms = assert harness.checkRows "extracted-platforms" rows;
    pkgs.runCommand "extracted-platforms" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.concatStrings (lib.mapAttrsToList runRefusal refused)}
      echo "PASS: extracted-platforms" > "$out"
    '';
}
