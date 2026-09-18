# Does the carried patch set still apply — ALL of it, including the parts no
# default build touches?
#
# This repo tracks KiroCrew `main` at roughly four bumps a day, against ten
# patches. The applied ones are self-policing: a conflict fails the package
# build and the bump PR goes red. The DORMANT ones are not. Nothing builds
# them, so a rebase silently retires them, and the failure surfaces months
# later as "the fallback we carried for exactly this does not apply any more"
# — at the moment it is needed.
#
# A patch file nobody references has the same problem from the other side: it
# sits in `patches/`, reads as carried, and is inert. So this check asserts the
# directory listing and the recipe's manifest are the SAME SET, in both
# directions, before it applies anything.
#
# `-F 0` is load-bearing rather than strict-for-its-own-sake. `patch` will
# happily place a hunk at an offset or with fuzzed context, which is how a
# patch drifts onto the wrong lines and keeps reporting success. Zero fuzz
# makes a moved site a failure here instead of a wrong edit downstream.
{
  lib,
  pkgs,
  ...
}: {
  checks.kiro-crew-patches-apply = let
    crew = pkgs.ai.kiro-crew;
    inherit (crew.passthru) patchManifest;

    patchDir = ../patches;
    onDisk = lib.sort (a: b: a < b) (builtins.attrNames (builtins.readDir patchDir));
    declared =
      lib.sort (a: b: a < b)
      (map baseNameOf (patchManifest.python ++ patchManifest.frontend ++ patchManifest.dormant));

    # Spelled out rather than via `lib.subtractLists`, whose argument order is
    # `subtractLists toRemove fromList` — the opposite of how the call site
    # reads. It was correct, and a reviewer still read it backwards; a filter
    # naming its own predicate cannot be read backwards at all.
    orphaned = builtins.filter (f: !(builtins.elem f declared)) onDisk;
    missing = builtins.filter (f: !(builtins.elem f onDisk)) declared;

    # `patch` is given the file by store path, so the manifest's ORDER is what
    # decides application order — the same list the recipe hands to `patches`.
    applyAll = root: patches:
      lib.concatMapStrings (p: ''
        printf '  %s\n' "${baseNameOf p}"
        ${pkgs.gnupatch}/bin/patch -p1 -F 0 --no-backup-if-mismatch -d "${root}" <${p} \
          || fail "${baseNameOf p} does not apply cleanly at zero fuzz under ${root}"
      '')
      patches;
  in
    assert lib.assertMsg (orphaned == []) ''
      kiro-crew: these files sit in packages/kiro-crew/patches/ and no manifest
      entry references them, so nothing applies or verifies them:
        ${builtins.concatStringsSep "\n  " orphaned}
      Add them to the recipe's patchManifest (as applied or dormant), or delete them.
    '';
    assert lib.assertMsg (missing == []) ''
      kiro-crew: the recipe's patchManifest names files that are not in
      packages/kiro-crew/patches/:
        ${builtins.concatStringsSep "\n  " missing}
    '';
      pkgs.runCommandLocal "kiro-crew-patches-apply-check" {} ''
        fail() {
          printf 'kiro-crew-patches-apply: %s\n' "$1" >&2
          exit 1
        }

        # A writable copy of the SAME pinned tree the package builds from, so
        # this asks the question about the real source rather than a re-fetch.
        cp -R ${crew.src} tree
        chmod -R u+w tree

        echo "kiro-crew-patches-apply: applied set, repo root"
        ${applyAll "tree" patchManifest.python}

        # The frontend derivation sets `sourceRoot = "<src>/website"`, so its
        # patchPhase runs one level down and its diffs carry no `website/` path
        # component. Applying them at the repo root would fail; applying repo-root
        # diffs here would too. That asymmetry is why the fonts change is split
        # across two files, and this is what proves each half is rooted right.
        echo "kiro-crew-patches-apply: applied set, website root"
        ${applyAll "tree/website" patchManifest.frontend}

        # The dormant ones, on TOP of the applied set — which is the only state
        # they would ever be enabled from. Checking them against a pristine tree
        # instead would pass on a pair that conflicts in practice.
        echo "kiro-crew-patches-apply: dormant set, on top of the applied set"
        ${applyAll "tree" patchManifest.dormant}

        touch "$out"
      '';
}
