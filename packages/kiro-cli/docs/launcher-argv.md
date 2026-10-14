## Kiro launch defaults and argument composition

> **Last verified:** 2026-10-14 — ACP reads engine settings in the payload
> launchers; the packaged KAS wins over inherited overrides.
>
> Full historical measurements:
> `git show 8be06935:packages/kiro-cli/docs/launcher-argv.md`.

### Terminal and ACP have different consumers

Managed library, Home Manager and devenv configurations default
`cli.native.settings.chat.agentEngine` to `"v3"` through the existing settings
writer. Native terminal selection is explicit CLI > repository settings > global
settings. There is no terminal `--v3` injection. Every module feature is built
and tested against V3; other native engine values, including null (automatic
selection), warn. V3-only features additionally reject incompatible
declarations.

ACP does not read persisted `chat.agentEngine` itself. The payload's existing
`makeWrapper` launchers read `$KIRO_HOME/settings/cli.json` (default
`~/.kiro/settings/cli.json`) then `./.kiro/settings/cli.json`, with the repo
value winning. On `acp` only, they add `--agent-engine <value>` when a value
exists and no explicit engine flag was supplied. Both `--agent-engine` spellings
and launcher `--v1`, `--v2`, `--v3` win. Shared argv helpers skip value-taking
globals when recognizing ACP and stop at `--`. Without a setting, argv stays
unchanged. Settings changes do not create a new payload derivation.

Devenv's `.kiro` output, including the engine setting, applies when starting
Kiro at the project root: Kiro does not find that root from a subdirectory.

### Package and platform composition

`withBundlePatches` and `withRolloutFeatures` preserve each other. Linux applies
the settings bridge in the unwrapped payload before nixpkgs builds the FHS root
around it. `useFhsSandbox = false` selects that same payload directly.

Darwin's launcher shim executes the real packaged `.app` binary and sets argv0
to that path; an app-shaped argv0 alone on a hidden `bin` symlink was
insufficient in native CI. The native launcher discovers the app's chat binary
directly. Consequently the main launcher also supplies the ACP default, while
direct `bin/kiro-cli-chat` has its own guarded default. Never change the Darwin
shim to `exec -a "$0"`: it must retain the real app path as executable and
argv0.

The packaged KAS always wins: both launchers set `KIRO_KAS_SERVER_PATH` with
`--set`. A differing inherited path produces one stderr line saying it was
detected and ignored and naming the selected path; the same path is silent. The
main launcher exports the selected path before dispatch, so the direct chat
launcher does not repeat the warning. TERM and platform setup remain ordinary
build wrapper arguments. No wrapper injects `--tui`.

### Trust injection remains engine-sensitive

`--trust-tools` is a chat-subcommand option, so the payload launcher adds it to
`chat` and `acp` only. ACP with V3 rejects it, while terminal V3 accepts it. The
payload first resolves the effective ACP engine from argv and settings, then
applies the configured trust grant only when that engine accepts it. The
module's chat wrapper hands the grant through `NAT_KIRO_TRUST_TOOLS`; the
payload unsets that private value before executing the native binary. This order
prevents a repository V3 override from receiving a conflicting `--trust-tools`
flag.

Linux's FHS root supplies `/usr/bin/kiro-cli-chat` ahead of inherited PATH. An
outer chat wrapper would be bypassed on launcher dispatch, so trust handling is
placed in the selected payload with `withFhsPayload`. Environment exports and
extra packages remain outside, inherited through bubblewrap. Custom packages
advertising an FHS payload must support this recomposition or evaluation refuses
the configuration.

Home Manager also translates representable `trustedMcpTools` entries into
`permissions.yaml` when the effective declared engine is V3. Devenv does not
have this permissions writer; withholding the ACP flag there does not create an
equivalent declarative grant. The external ACP client owns interactive approval.

Do not infer feature availability from KAS/TUI JavaScript alone: the Rust chat
binary recomputes the enabled rollout list before spawning the frontend.
Friendly features and global-only client settings are documented in
[workflow-gating.md](workflow-gating.md).

### Verification

- `checks/native-startup.py` runs both native entry points with no prompt and
  checks the launch decision before input validation. Opposing global/repository
  values and explicit flags prove engine selection, not just settings reads.
- `checks/kas-dispatch.py` captures the selected KAS under fresh and stale
  homes, checks default ACP and both explicit V2 spellings on main/direct entry
  points, and initializes real ACP without a model turn.
- `checks/kiro-wrapper-argv.nix` exercises remaining trust, environment and PATH
  handling against dispatching stubs.
- `checks/kiro-fhs-contract.nix` checks the selected rootfs payload and
  inherited PATH bridge. Nested bubblewrap execution is a separate host test
  because Nix build sandboxes cannot reliably create nested user namespaces.

The module wrapper still ends in `exec -a "$0" <realBin> "$@"`; the behavioral
check reads that shape. This contract is separate from the Darwin build shim's
app-path argv0 requirement.

### Prompt corpus and the static/runtime boundary

Build `ciPackages.<system>.kiro-cli.kas.promptCorpus` explicitly to inspect the
packaged server. This lazy, proprietary JSON output is outside the CLI runtime
closure and keeps the `kiro-cli` cache exclusion prefix. Selected KAS builds
instead extract a temporary corpus from their own freshly unpacked server before
patching; they never depend on an installed stock KAS.

`extract/prompts.mjs` uses the existing TypeScript parser. It reads every string
literal and every template's static chunks, including short strings, with UTF-8
byte ranges into the fingerprinted source. Untagged chunks contain cooked text.
Chunks marked `tagged: true` contain TypeScript parser text, not a promised
cooked or effective value: legal invalid escapes in tagged templates can have an
undefined cooked value. It does not import KAS or evaluate vendor expressions.
Isolated evaluation cannot recover session-dependent prompt builders without
fabricating runtime services, so AST extraction is the narrower technique here.
The entire literal index is a searchable superset, **not a claim that every
bundled string is a prompt**.

Five inspected entry points are named separately: identity, system features,
Vibe, workflow creator and workflow orchestration. Each points to its decoded
chunk and containing callable's range when one exists. Select their source
ranges in the same packaged server to inspect callers and branches; minified
names are not stable identifiers. The corpus also contains the workspace, shell,
steering, tool-description, spec, agent-profile and memory guidance those entry
points alone do not enumerate. No keyword or length filter excludes newly
shipped strings.

Each JavaScript template records an ordered sequence of chunk references and
exact interpolation expressions with source ranges, with tagged chunks subject
to the parser-text limitation above. Nested templates have their own records.
Expressions such as clock reads, workspace lookups, feature branches and helper
calls remain unevaluated. Mustache-shaped text such as `{{machineId}}` and
`{{worktree_path}}` remains decoded literal text: it is a later formatting
boundary, not JavaScript interpolation. Concatenation, conditional inclusion,
session state, external prompt files, and saved-session prompt reuse remain
runtime assembly; the corpus does not claim to reconstruct the effective prompt
of a session. In particular, a persisted initial system message may bypass fresh
prompt construction.

`lib/kiro-bundle-patch.py` finds the existing named selections in these decoded
chunks, checks the source fingerprint and uniqueness, and replaces only the
selected token contents. Quoting changes in a release no longer invalidate a
decoded match. Serialization escapes the actual quote and template delimiters,
preserving interpolation expressions. Tagged templates are refused because a tag
may interpret raw escapes differently. Missing or duplicate decoded matches fail
closed before any output write.

The existing owner extraction/check/regeneration contract carries the corpus
digest, chunk/template counts and named groups alongside other Kiro facts. These
measurements remain raw drift evidence, not an unused declared API. The real
vendor check consumes named groups to assert the inspected entry points and
their interpolation boundaries. Full vendor prompt text stays in the explicit
inspection artifact, not the committed fact files. Ordinary module/package
evaluation reads committed facts and never realizes this corpus through IFD.

Inspect the full corpus with Node or Python: JavaScript strings can contain lone
UTF-16 surrogate code units, which the JSON preserves but `jq` rejects. The
facts pipeline reads only the scalar summary through Node before combining it
with other facts.

The extraction sources stay distinct:

| Artifact                      | Facts                                     | Technique                                                                              |
| ----------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------- |
| KAS JavaScript                | Hook vocabulary, prompt corpus            | Static TypeScript AST; decoded literal text and unresolved expressions                 |
| Native chat executable        | Rollout manifest and patchability         | Validated text matching against embedded manifest entries                              |
| Public documentation snapshot | Model suggestions                         | Separate `kiro-model-catalog` owner and document parser                                |
| TUI JavaScript                | Settings registry and workspace allowlist | Sandboxed host materialization, then AST validation and isolated expression evaluation |

`kiro-bundle-patch` executes synthetic fixtures across single, double and
template quotes, UTF-8 offsets, escaped content and runtime holes; it refuses
stale corpora, tagged selections and anchor drift. The real
`kiro-bundle-patch-drift` check runs on both native builders, compares all eight
tweak selections, checks JavaScript syntax, executes only the changed standalone
literal tokens to verify their values, and proves all other decoded text and
source bytes survive. Existing KAS resource, initialization and dispatch checks
remain in place. Native Darwin execution is CI evidence; parsing a Darwin bundle
on Linux alone is not that evidence.
