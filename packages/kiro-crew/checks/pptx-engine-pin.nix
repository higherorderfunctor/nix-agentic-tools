# The PPTX Maker engine's four pins are COPIES of constants in KiroCrew's
# `engine_source.py`, and this is the gate that keeps the copies honest.
#
# Why copies at all: reading them out of the fetched KiroCrew source at EVAL
# time would be import-from-derivation. This repo pays for IFD with a CI warm
# step, which is not worth spending on four strings. So the values are written
# out in the recipe and compared here, at BUILD time, where reading the source
# is ordinary.
#
# Why it matters, and why all four rather than just the digest: the repo tracks
# KiroCrew `main`, so upstream can re-pin the engine at any of the ~4 bumps a
# day. A digest-only check would pass a bump that moved the COMMIT alone, and
# the seeded tree's marker would then carry a commit upstream no longer
# recognizes — `is_installed()` compares both, so the gateway would silently
# re-fetch over the store-supplied tree and the packaging would be a no-op that
# nothing reports. The tag is display-only to upstream, but a stale one is a
# lie shown in the UI, which is the same class of quiet wrongness.
{pkgs, ...}: {
  checks.kiro-crew-pptx-engine-pin = let
    engine = pkgs.ai.kiro-crew-pptx-engine;
    crewSrc = pkgs.ai.kiro-crew.src;

    # name = the Python constant; value = ours. One row per pin so the loop
    # below cannot drift from the recipe's `passthru`.
    expected = {
      ENGINE_COMMIT = engine.commit;
      ENGINE_REPO = engine.repo;
      ENGINE_TAG = engine.tag;
      ENGINE_TARBALL_SHA256 = engine.sha256;
    };
  in
    pkgs.runCommandLocal "kiro-crew-pptx-engine-pin-check" {} ''
      fail() {
        printf 'kiro-crew-pptx-engine-pin: %s\n' "$1" >&2
        exit 1
      }

      engineSource="${crewSrc}/src/kiro_crew/apps/builtins/pptx_maker/backend/engine_source.py"
      [ -f "$engineSource" ] || fail "engine_source.py not found at $engineSource — upstream moved it"

      check_pin() {
        local constant="$1" ours="$2" upstream

        # Upstream writes each of these as a module-level assignment to a
        # double-quoted literal. Tolerate either quote style and surrounding
        # whitespace; do NOT tolerate a missing match.
        upstream="$(
          ${pkgs.gnugrep}/bin/grep -oE "^$constant[[:space:]]*=[[:space:]]*[\"'][^\"']*[\"']" "$engineSource" \
            | ${pkgs.coreutils}/bin/head -n1 \
            | ${pkgs.gnused}/bin/sed -E "s/^$constant[[:space:]]*=[[:space:]]*[\"'](.*)[\"']$/\1/"
        )"

        # A check that silently compares nothing to nothing is worse than no
        # check. An upstream rename or reformat fails LOUDLY here rather than
        # passing on two empty strings.
        [ -n "$upstream" ] || fail "could not extract $constant from engine_source.py. Upstream renamed or reformatted it; re-read the constant and update the recipe."

        if [ "$upstream" != "$ours" ]; then
          fail "$constant drift.
        recipe:   $ours
        upstream: $upstream
      Upstream re-pinned the PPTX Maker engine. Update the matching entry in
      packages/kiro-crew/packages/ai/kiro-crew-pptx-engine/package.nix. All four
      pins move together — upstream's own comment says bumping the commit alone
      fails verification on every host."
        fi

        printf 'kiro-crew-pptx-engine-pin: %s matches upstream\n' "$constant"
      }

      ${builtins.concatStringsSep "\n" (
        pkgs.lib.mapAttrsToList (constant: ours: ''check_pin "${constant}" "${ours}"'') expected
      )}

      # ── The positive control ────────────────────────────────────────────
      #
      # Everything above compares the RECIPE's strings to upstream's. None of
      # it proves the built tree carries a marker upstream will accept, and
      # that is the failure that costs the most while reporting the least:
      # `is_installed()` reads two keys BY NAME off the marker JSON, and a
      # marker whose keys are spelled differently makes the seeded tree read as
      # absent. The gateway then fetches the engine over it, the packaging
      # becomes a no-op, and everything still exits 0.
      #
      # This happened — the marker shipped `sha256Hex` for one build, because
      # it is generated from the recipe's own attribute names. So re-implement
      # `is_installed()` here, against the REAL output, by the same two keys.
      # Referencing ${engine} is also what puts the built package in this
      # check's closure, so a bump changes this drv rather than serving a
      # cached pass — see decision 8 in the register.
      marker="${engine}/.kirocrew-engine.json"
      [ -f "$marker" ] || fail "the built engine carries no .kirocrew-engine.json. Upstream's is_installed() reports a tree without one as absent, so the gateway would silently re-fetch over it."

      markerCommit="$(${pkgs.jq}/bin/jq -er '.commit // empty' "$marker")" \
        || fail "the marker has no 'commit' key. is_installed() reads marker.get(\"commit\") and compares it to ENGINE_COMMIT; a differently-spelled key makes the seeded tree read as absent."
      markerSha="$(${pkgs.jq}/bin/jq -er '.sha256 // empty' "$marker")" \
        || fail "the marker has no 'sha256' key. is_installed() reads marker.get(\"sha256\") and compares it to ENGINE_TARBALL_SHA256; a differently-spelled key makes the seeded tree read as absent."

      [ "$markerCommit" = "${engine.commit}" ] || fail "marker commit '$markerCommit' is not the recipe's '${engine.commit}'"
      [ "$markerSha" = "${engine.sha256}" ] || fail "marker sha256 '$markerSha' is not the recipe's '${engine.sha256}'"

      printf 'kiro-crew-pptx-engine-pin: the marker satisfies is_installed() (%s)\n' "$markerCommit"

      touch "$out"
    '';
}
