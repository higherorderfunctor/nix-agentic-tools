# kiro-crew-embed-model — the Qwen3-Embedding-0.6B Q8_0 GGUF that KiroCrew
# otherwise downloads from a CDN on first gateway start.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input routes
# through this repo's pinned nixpkgs rather than the consumer's. That is what
# gives store-path parity against CI's standalone build — see
# dev/fragments/overlays/overlay-pattern.md.
{pkgs, ...}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) fetchurl lib runCommand;

  # Upstream's own pin, `_GGUF_SHA256` in `src/kiro_crew/embeddings.py`.
  #
  # This is a COPY of that value, deliberately. Reading it out of the fetched
  # KiroCrew source at eval time would be import-from-derivation, which this
  # repo pays for with a CI warm step and which is not worth it for one hash.
  # The drift that a copy invites is caught by `checks.nix`'s
  # `kiro-crew-embed-model-digest`, which greps the pinned source at BUILD time
  # and fails when the two disagree. Copy plus a gate, not a copy alone —
  # the repo tracks KiroCrew `main`, so upstream can republish at any bump.
  sha256Hex = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439";

  # The filename upstream's downloader would have written. Exposed through
  # `passthru` so the consumer never hardcodes it in a second place.
  modelFile = "qwen3-embedding-0.6b.gguf";

  model = fetchurl {
    name = "qwen3-embedding-0.6b-q8_0.gguf";
    # Two sources, one hash. The bytes were verified identical: 639,150,592
    # bytes, and the git-LFS pointer in Qwen's own repo declares this exact
    # oid, so AWS's CDN re-serves Qwen's published file rather than a
    # third-party conversion of it.
    #
    # The HuggingFace URL is COMMIT-pinned. `resolve/main/` tracks a mutable
    # branch and would silently change what it serves. The CloudFront URL has
    # the mirror-image weakness — its path carries no version — which is the
    # other half of why the digest gate above exists.
    urls = [
      "https://d3j0sthz5doyui.cloudfront.net/models/${modelFile}"
      "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf"
    ];
    # Converted from the hex above rather than written twice: the hex is the
    # single source of truth, because it is the form the digest gate compares
    # against upstream's `_GGUF_SHA256`.
    hash = builtins.convertHash {
      hash = "sha256:${sha256Hex}";
      toHashFormat = "sri";
    };
  };
in
  runCommand "kiro-crew-embed-model" {
    inherit model modelFile sha256Hex;

    passthru = {inherit model modelFile sha256Hex;};

    meta = {
      description = "Qwen3-Embedding-0.6B Q8_0 GGUF embedding model for Kiro Crew";
      homepage = "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF";
      license = lib.licenses.asl20;
      # Trained weights: not source, not native code, not bytecode.
      sourceProvenance = [lib.sourceTypes.binaryBytecode];
    };
  } ''
    mkdir -p "$out"

    # Symlink rather than copy. `validate_custom_model_path` in
    # `embeddings.py` tests `is_file()` and a size floor, and Python's
    # `is_file()` follows symlinks — so this passes while keeping one copy of
    # 610 MB in the store instead of two. The link is a store reference, so
    # the fetched path is retained as a dependency and cannot be GC'd away.
    ln -s "$model" "$out/$modelFile"

    # Apache-2.0 section 4(a) requires the licence to travel with the work,
    # and NEITHER Qwen embedding repo ships a LICENSE file — the canonical
    # text lives one repo upstream, in the base model. A bare `fetchurl`
    # output would therefore redistribute the weights through a public binary
    # cache without the notice. Hence this wrapper: the licence and the
    # attribution are the reason this is a derivation and not just a fetch.
    cp ${./../../../licenses/Apache-2.0} "$out/LICENSE"

    # QUOTED heredoc: nothing in the body is interpreted by the shell, so the
    # backticks below need no escaping and cannot become command substitution.
    # The one value that does vary is appended afterwards instead, which keeps
    # the body free of interpolation entirely. An unquoted heredoc would work
    # here only by accident.
    cat > "$out/ATTRIBUTION" <<'EOF'
    Qwen3-Embedding-0.6B, Q8_0 GGUF quantization.

    Copyright the Qwen team, Alibaba Cloud.
    Licensed under the Apache License, Version 2.0; see LICENSE.

    Upstream: https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF
    Revision: 370f27d7550e0def9b39c1f16d3fbaa13aa67728

    Redistributed unmodified. The licence declaration is the GGUF header's
    own `general.license` field, read from these exact bytes.
    EOF

    printf 'sha256:   %s\n' "$sha256Hex" >> "$out/ATTRIBUTION"
  ''
