# Generated builtin identities

> **Last verified:** 2026-10-23 — M3 derives builtin identities from the
> packaged runtime and its registration source, installs their model and
> activates the shared run fingerprint under one fixed evaluation policy.

## Terms

- Alias: another exported name for the same builtin identity.
- Builtin: a primitive exported by the pinned Nix runtime.
- Confidence: whether a record has recognized registration-source evidence.
- Evidence span: a source path and inclusive line range supporting metadata.
- Export: a name exposed globally or under `builtins`.
- Fingerprint: a content hash identifying the complete generated model.
- Identity: an opaque label for one builtin in one runtime/source pair.
- JSON: the structured data format used for the installed model asset.
- Model: versioned builtin facts derived from runtime and source inputs.
- Namespace: the export container; the empty string denotes global names.
- NAR hash: Nix's content hash of a directory tree.
- Opaque behavior: no claim about what invoking the primitive does.
- Oracle: an expected answer obtained independently of model generation.
- Parser: a program that recognizes grammatical structure in source text.
- Pin: a fixed input version or content identity.
- Policy: the fixed feature, purity and plugin settings for this model.
- QL: CodeQL's query language.
- Registration: C++ source that declares a runtime primitive or constant.
- Runtime: the packaged Nix executable used to enumerate exports.
- Sentinel: a competing test value used to reveal which name wins.
- Tree-sitter: the parsing library used to recognize C++ registrations.

## What is generated and why

`models/builtins/generate.py` reads the actual `builtins` export inventory from
the runtime under `models/builtins/policy.json`: exactly `flakes nix-command`,
pure evaluation and no plugins. The generator clears ambient Nix configuration
sources and search paths; the installed evaluator consumes that same policy in
its existing isolated invocation. The bundle covers this scope only, not
arbitrary user configurations. It probes candidate global names with competing
`with` sentinels, without invoking exported functions. Each inventory member
gets a distinct identity; observed global and namespace aliases share it. Names
missing from the inventory get no identity.

A tree-sitter C++ parser reads supported `RegisterPrimOp`, `addConstant` and
`addPrimOp` registration forms under the same runtime's `src/libexpr/`.
Recognized records retain argument names, literal documentation and evidence
spans with `source` confidence. Missing registration evidence yields `unknown`
confidence and null metadata. Unsupported or computed documentation remains null
even when other registration evidence exists. Every record keeps opaque
behavior; metadata proves no function summary.

The generator records its version, exact stripped `nix --version` output and
source NAR hash. The JSON also records the enforced policy. `modelVersion` is
`sha256:` plus the hash of compact, sorted-key UTF-8 JSON excluding that field.
This identifies content independently of display formatting.

`generated/models/builtins.json` is the sole model representation. The generated
`builtins.qll` is a mechanical projection of that JSON, not a second authored
inventory. Models add no evaluation tables or syntax rules.

## Installation and consumers

The existing `lib/packaging.nix` assembly supplies the runtime and its own `src`
together. It passes JSON through the shared generated-tree formatter and
preserves generated QL bytes. The library installs `models/builtins.json` and
`nix/internal/generated/Builtins.qll`.

Queries import `nix.internal.BuiltinModels`.
`builtinIdentity(namespace, name, identity)` exposes identities only when the
database's `nx_runs` model fingerprint matches the installed model.
`runtimeIdentity`, `runtimeSourceHash` and `modelFingerprint` describe the
bundle; `supportsRuntime` checks exactly its runtime/source pair within the
fixed policy above. It does not test arbitrary runtime settings. A different
policy changes the complete model fingerprint; a missing or mismatched model
cannot establish builtin resolution.

The existing [shared run identity](installed-extractor.md) carries this
fingerprint. [Target admission](target-contract.md) rejects an explicitly
requested different model. Legacy `not-requested` targets remain valid. Lexical
binding resolution and shadowing belong to the name resolver; import edges
belong to the later import domain. This module supplies identities for those
consumers without resolving source names itself.

## Verification and changes

`checks.nix` imports `checks/builtin-models.nix`, exposing the Linux check
`checks.x86_64-linux.codeql-nix-builtin-models`. Its explicit nonempty Python
runner checks runtime inventory, alias uniqueness, source-backed `map` metadata,
opaque records, content fingerprints and shared run propagation. It regenerates
twice, applies the assembly's JSON formatter and compares committed and
installed bytes.

The same suite explicitly runs `NameBindings.ql` and `ModelCompatibility.ql`
against the installed extractor and library, using independent expected rows. A
real Nix oracle compares global and namespace `import`, competing sentinel
values and a safely renamed local binding. These checks establish the
builtin-identity part of names, rather than a complete lexical resolver.

To change generation, update the generator policy or runtime/source inputs
together, preserving the shared policy enforced by generation and installed
evaluation. Run
`python models/builtins/generate.py --nix NIX --source PINNED_NIX_SOURCE --output DIRECTORY`
from the owner directory, format the JSON through the assembly's treefmt policy,
and review both generated artifacts together. Never hand-edit the generated
inventory or projection. Preserve exact compatibility, explicit unknowns and
independent expectations; run the owner check through CI and update this note
when these obligations change.
