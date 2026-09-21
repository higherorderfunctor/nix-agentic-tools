# Qwen model weights

`pkgs.models."qwen3-embedding-0.6b-q8_0"` provides Qwen3-Embedding-0.6B in Q8_0
GGUF format. The flat flake output has the same basename:

```sh
nix build '.#"qwen3-embedding-0.6b-q8_0"'
```

Use `${model}/${model.modelFile}` for the installed file. `model.model` exposes
the fetched store path; `model.sha256Hex` and `model.format` expose its digest
and format. The package carries `LICENSE` and `ATTRIBUTION` alongside a symlink
to the weights. The 639,150,592-byte artifact occupies about 610 MiB once in the
store and is included in the binary-cache closure.

The publisher owns the package; HuggingFace and the CDN are mirrors of the same
pinned bytes. The checked-in Apache-2.0 text is copied unchanged from the
reference KiroCrew model package, which sourced the licence from Qwen's
base-model repository because the embedding repositories omit it.

## Updates

The owner registry invokes `passthru.updateScript` through
`nix-update --use-update-script`. It resolves HuggingFace `main` to a full
commit, selects this exact filename, checks its LFS SHA-256, verifies the
artifact with Nix, and atomically replaces the inline revision and hex digest.
An unchanged pair does not download or rewrite anything. The generated fetch URL
always uses the resolved commit.

For a chosen revision, build and invoke the script from the repository root:

```sh
updater=$(nix build '.#"qwen3-embedding-0.6b-q8_0".updateScript' --no-link --print-out-paths)
"$updater" --revision 370f27d7550e0def9b39c1f16d3fbaa13aa67728
treefmt packages/qwen/packages/models/qwen3-embedding-0.6b-q8_0/package.nix
```

Every model build reads `general.license` from the actual GGUF header and
rejects any value other than `apache-2.0`, including a missing declaration. A
changed licence therefore requires manual review before a new revision can be
distributed.

The updater does not change the model family, quantization, filename, mirror
URL, licence, or attribution policy. It supports public HuggingFace artifacts
with LFS metadata; private repositories and non-LFS storage are outside this
owner's updater. Downstream compatibility gates remain the consumer's
responsibility.

No `ai.models` option is introduced. A configuration registry is deferred until
consumers need to select models at configuration time.
