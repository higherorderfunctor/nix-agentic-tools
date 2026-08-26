# strictdoc — the latest upstream release on this repository's update cadence,
# rather than whatever the nixpkgs pin happens to carry. The base is nixpkgs'
# recipe, so its build system, dependency set and import check stay upstream-
# owned; this overlay moves the pin and makes the two dependency adjustments the
# release needs.
#
# Every sdoc session, flake check and devShell in this repository runs this
# package (SLICE-STRICTDOC-OVERLAY, docs/plans/strictdoc-tooling/
# 03-executable-rules.sdoc). It is step zero of the executable-rules roadmap:
# the grammar gate, the writer CLI and the lifecycle model are all measured
# against the latest release, so they should also run on it.
#
# Release-tracked (upstream ships roughly three releases a month), on the same
# fetchzip + sidecar + ghArchiveUpdateScript contract as ./beads.nix. The one
# wrinkle is the TAG PREFIX: strictdoc tags releases bare (`0.28.3`, not
# `v0.28.3`), so both the archive URL and the version check pass
# `tagPrefix = ""`.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/cache-hit-parity.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchzip;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./strictdoc-sources.json);
  sourcesFile = "overlays/dev-tools/strictdoc-sources.json";

  # ── Dependency adjustment 1: reqif ────────────────────────────────────
  # strictdoc 0.28.x declares `reqif >= 0.1.0, == 0.1.*`; the nixpkgs pin is
  # still on the 0.0.x line, so the runtime dependency check rejects the build
  # outright. 0.1.0 is a pure version move for our purposes — its own
  # dependency list (lxml, jinja2, xmlschema, openpyxl) is byte-identical to
  # 0.0.54's, so nixpkgs' expression needs nothing but a new src.
  #
  # Pinned INLINE rather than in the sidecar on purpose: `mkUpdateScript`
  # rebuilds the sidecar from scratch on every write, so a second package's
  # pin parked there would be erased by the next sweep. Drift is loud instead
  # of silent — strictdoc's declared constraint is checked at build time, so a
  # future release that outgrows this pin fails the build rather than shipping.
  reqifVersion = "0.1.0";
  reqif = ourPkgs.python3Packages.reqif.overridePythonAttrs (old: {
    version = reqifVersion;
    src = ourPkgs.fetchFromGitHub {
      owner = "strictdoc-project";
      repo = "reqif";
      tag = reqifVersion;
      hash = "sha256-aMjq2x9/aC7HRDL2T2v/yvz+TP+AAKSY3e/TmboKq9Q=";
    };
    # nixpkgs builds `meta.changelog` from the fetcher's `tag`, and `rec`
    # captured the OLD version — `${src.tag}` in the base expression resolves
    # against the original `src`, not ours. Repoint it at the pinned tag so the
    # link stays valid rather than naming a version this derivation is not.
    meta =
      old.meta
      // {
        changelog = "https://github.com/strictdoc-project/reqif/releases/tag/${reqifVersion}";
      };
  });
in
  ourPkgs.strictdoc.overridePythonAttrs (old: {
    inherit (sources) version;
    src = fetchzip {inherit (sources.src) url hash;};

    # Substitution by IDENTITY, not by position: nixpkgs' `dependencies` list is
    # upstream-owned and reorders freely, and a positional splice would silently
    # replace the wrong package the first time it does. Throw if the entry we
    # are replacing is not there any more — that means nixpkgs restructured the
    # dependency set and this override needs re-reading, not skipping.
    dependencies = let
      swapped =
        map (
          dep:
            if (dep.pname or null) == "reqif"
            then reqif
            else dep
        )
        old.dependencies;
    in
      if builtins.any (dep: (dep.pname or null) == "reqif") old.dependencies
      then swapped
      else throw "strictdoc: nixpkgs no longer lists reqif among the dependencies";

    # ── Dependency adjustment 2: pygments ───────────────────────────────
    # strictdoc 0.28.x pins `pygments == 2.21.0` exactly; the nixpkgs pin is
    # 2.20.0. Relaxed rather than overridden because pygments sits under a
    # large part of the Python package set, so pinning it here would fork the
    # closure of everything strictdoc pulls in for a single patch-level move.
    # strictdoc uses pygments to colour source excerpts in its HTML export —
    # nothing this repository's validate-and-export loop reads — so the risk of
    # the two minor versions disagreeing is confined to rendering.
    #
    # Extended from upstream's list rather than restated, so nixpkgs adding a
    # third relaxation is inherited instead of dropped.
    pythonRelaxDeps = (old.pythonRelaxDeps or []) ++ ["pygments"];

    # Same `finalAttrs.src.tag` trap as reqif above, and it bites harder here:
    # our `src` is a `fetchzip`, which has no `tag` attribute at all, so
    # anything that reads `meta.changelog` (nix-update does) dies on a missing
    # attribute rather than on a stale link.
    meta =
      old.meta
      // {
        changelog = "https://github.com/strictdoc-project/strictdoc/releases/tag/${sources.version}";
      };

    # The slice's own acceptance condition — `strictdoc version` reports the
    # release we pinned — asserted at build time rather than left to a session
    # to notice. Catches the whole class of override seams that evaluate fine
    # and produce upstream's version anyway.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      ${ourPkgs.coreutils}/bin/env -i HOME="$TMPDIR" "$out/bin/strictdoc" version \
        | ${ourPkgs.gnugrep}/bin/grep -F "${sources.version}"

      runHook postInstallCheck
    '';

    passthru =
      (old.passthru or {})
      // {
        updateScript = vu.ghArchiveUpdateScript {
          pkgs = ourPkgs;
          pname = "strictdoc";
          repo = "strictdoc-project/strictdoc";
          inherit sourcesFile;
          tagPrefix = "";
        };
      };
  })
