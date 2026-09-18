# The embedding model's hash is a COPY of upstream's `_GGUF_SHA256`, and this
# is the gate that keeps the copy honest.
#
# Why a copy at all: reading the constant out of the fetched KiroCrew source at
# EVAL time would be import-from-derivation. This repo pays for IFD with a CI
# warm step, which is not worth spending on one hash. So the value is written
# out in the recipe and compared here, at BUILD time, where reading the source
# is ordinary.
#
# Why it matters: the repo tracks KiroCrew `main`, so upstream can republish
# the model at any of the ~4 bumps a day. The CloudFront URL carries no version
# in its path, so a republished model changes what that URL serves while the
# recipe still names the old digest — the fetch would then fail with a hash
# mismatch that names nothing useful. This check fails first, and says why.
{pkgs, ...}: {
  checks.kiro-crew-embed-model-digest = let
    model = pkgs.ai.kiro-crew-embed-model;
    crewSrc = pkgs.ai.kiro-crew.src;
  in
    pkgs.runCommandLocal "kiro-crew-embed-model-digest-check" {} ''
      fail() {
        printf 'kiro-crew-embed-model-digest: %s\n' "$1" >&2
        exit 1
      }

      embeddings="${crewSrc}/src/kiro_crew/embeddings.py"
      [ -f "$embeddings" ] || fail "embeddings.py not found at $embeddings — upstream moved it"

      # Extract the 64-hex value assigned to _GGUF_SHA256, tolerating either
      # quote style and surrounding whitespace.
      #
      # `|| :` is not sloppiness, it is what keeps the diagnostic below
      # REACHABLE. A no-match grep exits 1, stdenv's setup.sh arms errexit and
      # pipefail, so a bare assignment would abort the builder on the very
      # input the shape check exists to report — and the failure would surface
      # as a bare non-zero builder with no message at all. Absence is handled
      # by the `case` below, loudly; it must not be handled here, silently.
      upstream="$(
        ${pkgs.gnugrep}/bin/grep -oE '_GGUF_SHA256[[:space:]]*=[[:space:]]*["'"'"'][0-9a-f]{64}["'"'"']' "$embeddings" \
          | ${pkgs.gnugrep}/bin/grep -oE '[0-9a-f]{64}' \
          | ${pkgs.coreutils}/bin/head -n1 \
          || :
      )"

      # A check that silently compares nothing to nothing is worse than no
      # check. If upstream renames the constant or changes its literal form,
      # this fails LOUDLY rather than passing on two empty strings.
      case "$upstream" in
        ????????????????????????????????????????????????????????????????) : ;;
        *) fail "could not extract a 64-hex _GGUF_SHA256 from embeddings.py (got: '$upstream'). Upstream renamed or reformatted it; re-read the constant and update the recipe." ;;
      esac

      ours="${model.sha256Hex}"

      if [ "$upstream" != "$ours" ]; then
        fail "digest drift.
        recipe:   $ours
        upstream: $upstream
      Upstream republished the embedding model. Update sha256Hex in
      packages/kiro-crew/packages/ai/kiro-crew-embed-model/package.nix to the
      upstream value, re-pin the HuggingFace revision to the matching commit,
      and re-verify the licence field in the new GGUF header before trusting
      the Apache-2.0 claim."
      fi

      printf 'kiro-crew-embed-model-digest: recipe matches upstream (%s)\n' "$ours"
      touch "$out"
    '';
}
