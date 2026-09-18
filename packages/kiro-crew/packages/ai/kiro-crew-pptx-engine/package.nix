# kiro-crew-pptx-engine — the Spec-Driven Presentation Maker tree that
# KiroCrew's built-in PPTX Maker app otherwise downloads from GitHub the first
# time the app is provisioned.
#
# A SEPARATE UPSTREAM, which is the whole reason this is its own derivation
# rather than another phase of the kiro-crew recipe: `aws-samples/
# sample-spec-driven-presentation-maker` is a different project under a
# different licence (MIT-0) on its own release cadence. Pooling it into
# kiro-crew's `src` would put two unrelated revs in one file and make the
# recipe resolver ambiguous — see the header of ../kiro-crew/package.nix.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input routes
# through this repo's pinned nixpkgs rather than the consumer's. That is what
# gives store-path parity against CI's standalone build — see
# dev/fragments/overlays/overlay-pattern.md.
{pkgs, ...}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) fetchurl gnutar lib runCommand;

  # ── Upstream KiroCrew's own pins ────────────────────────────────────────
  #
  # All four are COPIES of constants in
  # `src/kiro_crew/apps/builtins/pptx_maker/backend/engine_source.py`. Reading
  # them out of the fetched KiroCrew source at eval time would be
  # import-from-derivation, which this repo pays for with a CI warm step and
  # which is not worth spending on four strings. The copies are kept honest by
  # `checks/pptx-engine-pin.nix`, which greps that file at BUILD time and fails
  # when any of them disagrees. Copy plus a gate, not a copy alone — the repo
  # tracks KiroCrew `main`, so upstream can re-pin the engine at any bump.
  #
  # `sha256` is the one that matters. Upstream calls it "the trust anchor for
  # the whole engine": the commit and the tag are reported, but the digest is
  # what decides whether the bytes are allowed to run. It is spelled in hex
  # rather than SRI because hex is the form both upstream and the gate compare.
  #
  # THESE ATTRIBUTE NAMES ARE UPSTREAM'S MARKER KEYS, not our choice of
  # spelling. `sourceMarker` below is `builtins.toJSON` of this very set, so a
  # rename here silently renames a key `is_installed()` reads by name — and
  # that failure is invisible: the seeded tree reads as absent, the gateway
  # fetches over it, and the packaging becomes a no-op that exits 0. It was
  # caught once already, with `sha256Hex`. Do not "clarify" these names.
  pins = {
    commit = "b7c7fcf0972b33a480f1b717a3de5bc288d53742";
    repo = "https://github.com/aws-samples/sample-spec-driven-presentation-maker";
    sha256 = "ffe8e10b973cada1f6e99629ac780bde25461b432ad07943b4f15ca11c07dfe0";
    tag = "v0.3.8";
  };

  # The marker file upstream writes after a digest-verified extraction, and
  # the only thing `is_installed()` consults: it compares `commit` and
  # `sha256` against its own constants, and `installed_tag()` reports `tag`.
  # A pre-seeded tree without this file reads as "not installed" and the
  # gateway fetches over it.
  #
  # Built from `pins` rather than restated, so the four values are spelled
  # exactly once in this file. `builtins.toJSON` sorts keys where upstream's
  # `json.dumps` preserves insertion order; that is invisible to the reader,
  # which is `json.loads`.
  sourceMarker = builtins.toJSON pins;

  # `fetchurl`, not `fetchFromGitHub`, and not `fetchzip`. Upstream's digest is
  # of the PUBLISHED TARBALL — `shasum -a 256` over the bytes GitHub serves —
  # while `fetchzip` (which `fetchFromGitHub` wraps) hashes the unpacked NAR
  # instead. Only a flat fetch can carry upstream's own number, and carrying
  # upstream's own number is what lets the gate below compare the two directly
  # rather than comparing two things that are merely believed to correspond.
  #
  # Upstream documents why pinning a GitHub `/archive/` tarball is viable here:
  # for a fixed commit sha the generated archive is byte-stable, and they
  # re-derived the digest four times to establish it.
  archive = fetchurl {
    name = "sdpm-${builtins.substring 0 7 pins.commit}.tar.gz";
    url = "${pins.repo}/archive/${pins.commit}.tar.gz";
    # Converted rather than written twice: the hex in `pins` is the single
    # source of truth, because hex is the form upstream states, the form the
    # marker carries, and the form the gate compares.
    hash = builtins.convertHash {
      hash = "sha256:${pins.sha256}";
      toHashFormat = "sri";
    };
  };
in
  runCommand "kiro-crew-pptx-engine" {
    inherit archive;

    passthru =
      pins
      // {
        inherit archive sourceMarker;
        # The directory name upstream's `engine_root()` resolves to
        # (`paths._ENGINE_DIRNAME`). Exposed so a consumer seeding the tree
        # never spells it a second time.
        engineDirName = "sdpm";
      };

    meta = {
      description = "Spec-Driven Presentation Maker engine tree for Kiro Crew's PPTX Maker app";
      homepage = pins.repo;
      # MIT-0 — MIT with the attribution clause removed. nixpkgs spells it
      # `mit0`. The LICENSE text is installed below regardless: MIT-0 does not
      # require it to travel, but shipping a redistributed source tree with no
      # licence at all is the kind of quiet defect nothing reports.
      license = lib.licenses.mit0;
    };
  } ''
    mkdir -p "$out"

    # `--strip-components=1`: GitHub's archive wraps everything in a single
    # `<repo>-<commit>/` directory, and upstream's extractor strips exactly the
    # same level (`_single_child`, which REFUSES a tarball whose root holds
    # anything but one real directory). Matching it means the tree at $out is
    # the tree upstream expects at `engine_root()`.
    ${gnutar}/bin/tar -xzf "$archive" -C "$out" --strip-components=1

    # Upstream drops the archive's own permission bits on extraction
    # (`_FILE_MODE = 0o644`, `_DIR_MODE = 0o755`) so an upstream-set setuid or
    # group-writable bit cannot survive into the install. Do the same, for the
    # same reason — a pre-seeded tree must not be a weaker artifact than a
    # fetched one. The store strips the write bits afterwards; what survives
    # here is the group/other READ bits, which is what the runtime copy needs.
    find "$out" -type d -exec chmod 755 {} +
    find "$out" -type f -exec chmod 644 {} +

    # THE LICENCE, asserted rather than assumed. This derivation redistributes
    # a third party's source tree through a public binary cache, and a missing
    # notice is a redistribution defect that nothing would report — the build
    # would succeed and the cache would serve it. If upstream ever drops the
    # file, this fails here instead.
    if [ ! -f "$out/LICENSE" ]; then
      echo "kiro-crew-pptx-engine: the engine tarball ships no LICENSE" >&2
      echo "           Upstream is MIT-0 and previously carried one. Re-check" >&2
      echo "           the licence before redistributing these bytes." >&2
      exit 1
    fi

    # The marker LAST, mirroring `write_source_marker`'s own ordering: its
    # presence is the "this tree is the vetted one" signal, so it must never
    # exist beside a tree whose extraction did not complete.
    cat > "$out/.kirocrew-engine.json" <<'MARKER'
    ${sourceMarker}
    MARKER
  ''
