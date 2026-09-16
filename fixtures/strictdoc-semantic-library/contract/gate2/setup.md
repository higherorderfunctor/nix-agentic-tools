# Set up the native fixture and understand the proposed integration

The [tutorial](tutorial-dsl.md) teaches constraints. This page distinguishes
current native setup from the proposed schema, defaults and validation
integration. `g = grammar.dsl` exists today; `s = schema` and `c = constraint`
are new proposed layers supplied to the review prototype. None of the future
steps below is an installed semantic API claim.

## Current native setup

The source for these instructions is the retained
[fixture README](../../README.md), [devenv.nix](../../devenv.nix),
[devenv.yaml](../../devenv.yaml),
[StrictDoc configuration](../../strictdoc_config.py) and
[public toolchain facts](public-toolchain.md). Commands are copied for use in
the **retained fixture root**, where `bootstrap.sh` and `tests/devenv.sh` exist.
The documentation workflow inspected supplied copies and did not execute these
fixture commands.

The fixture uses normal devenv and the shared host/Nix store. Bash, Nix and
devenv are prerequisites. Its dependency file is:

```yaml
inputs:
  devenv:
    url: github:cachix/devenv/190959a9a4bb52d4802f076a90c3c4e3aa2e6fa2
  library:
    url: path:./.toolchain
  nixpkgs:
    url: github:NixOS/nixpkgs/c043004d1c6985732bcc1cbc5a9c9aecbbb4e0f0
```

The current complete module import and grammar binding are:

```nix
{ inputs, lib, pkgs, ... }:
let
  grammar = inputs.library.lib.ai.strictdocGrammar { inherit lib; };
in {
  imports = [ inputs.library.devenvModules.nix-agentic-tools ];
  ai.strictdoc = {
    enable = true;
    package = inputs.library.packages.${pkgs.stdenv.hostPlatform.system}.strictdoc;
    grammars.fixture = {
      elements = import ./grammar.nix { inherit (grammar) dsl; };
      target = "grammar.sgra";
    };
  };
}
```

Installed source delivery is the current default. The existing option
`ai.strictdoc.scribeSource = "installed"` can make that selection explicit. It
supplies the native `strictdoc`, `strictdoc-grammar-extract`, `scribe`,
`scribe-client` and `scribe-daemon` launchers. Project source mode is a
different choice and is not the neutral consumer setup taught here.

The current fixture's `grammar.nix` is a native source, not the new canonical
semantic declaration. Its historical FLAG string choice and temporary
`AUTHORED_BY`/`PARENT_FP` accommodations explain current Scribe operation. They
are not neutral domain policy. Their eventual removal from generic Scribe and
the clean neutral fixture remains a later qualification obligation.

The configuration binds `@repo` to `grammar.sgra` and includes `documents/**`
plus `grammar.sgra`:

```python
"""The retained fixture is a separate StrictDoc project."""

from strictdoc.api import ProjectConfig
from strictdoc.backend.json.json_format import JSONFormat
from strictdoc.backend.sdoc.sdoc_format import SDocFormat


def create_config() -> ProjectConfig:
    return ProjectConfig(
        dir_for_sdoc_cache="$TMPDIR",
        formats=[SDocFormat(), JSONFormat()],
        grammars={"@repo": "grammar.sgra"},
        include_doc_paths=["documents/**", "grammar.sgra"],
        project_title="StrictDoc semantic library fixture",
    )
```

The seed document carries the import needed by the first native `new`. Its
complete contents, retained in the native walkthrough, are:

```text
[DOCUMENT]
TITLE: Neutral fixture grammar seed

[GRAMMAR]
IMPORT_FROM_FILE: @repo
```

A daemon can start with an empty workspace, but that alone does not give `new` a
loaded grammar. Keep the seed under the configured document include path. The
seed contains no addressable semantic record. Every actual addressable element
must declare UID explicitly.

From the retained fixture root, refresh the filtered toolchain and generate
grammar:

```bash
bash bootstrap.sh
bash tests/devenv.sh tasks run generate:sgra
bash tests/devenv.sh up -d scribe
bash tests/devenv.sh shell -- scribe-client --root "$PWD" ping
```

Detached startup returns before readiness. Retry ping within a bounded startup
window and proceed only after the intended fixture root answers.
`tests/devenv.sh` clears inherited `DEVENV_*`, `DIRENV_*` and `SCRIBE_ROOT`,
changes to the fixture root and invokes ordinary devenv. It does not establish
semantic enforcement or an isolated store.

Inspect the native workspace after readiness:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" check
bash tests/devenv.sh shell -- scribe --root "$PWD" show F0
bash tests/devenv.sh shell -- scribe-client --root "$PWD" info
```

The existing native CLI has read verbs `show`, `list`, `check` and write verbs
`new`, `set`, `relate`, `unrelate`, `move`, `delete`. Each write supports
`--dry-run`. The current source audit finds that native `check` text can contain
findings without propagating the handler's nonzero result through the CLI; a
successful command exit is not the proposed semantic admission result.

For the retained fresh base, these existing commands demonstrate Parent/Child
ownership:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" new BAR --uid M --path documents/M.sdoc --relate P=F0 --relate Q=F2
bash tests/devenv.sh shell -- scribe --root "$PWD" relate F1a --role R --target F2
```

M owns both declarations, giving native `F0 → M → F2`. Initial relations on
`new` exist today. These commands are separate writes and do not prove
multi-operation atomicity or custom constraint checks. Do not load the retained
example snapshots alongside the base: they repeat UIDs.

For current-runtime cleanup after those two example mutations:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate F1a --role R --target F2
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate M --role Q --target F2
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate M --role P --target F0
bash tests/devenv.sh shell -- scribe --root "$PWD" delete M
bash tests/devenv.sh down
```

Those cleanup writes can temporarily leave an incomplete BAR because the current
runtime lacks the proposed counts. They are not a future semantic recipe.

After a grammar-only edit, regenerate and explicitly reload the running fixture:

```bash
bash tests/devenv.sh tasks run generate:sgra
bash tests/devenv.sh shell -- scribe-client --root "$PWD" reload
```

After toolchain code or root dependency-lock changes, refresh with
`bash bootstrap.sh` and restart the daemon. Bootstrap builds the public filtered
source, replaces ignored `.toolchain` and refreshes the native lock. Edit the
source grammar, not generated `grammar.sgra`, toolchain artifacts or store
files.

The existing native probe command is:

```bash
bash tests/devenv.sh shell -- strictdoc-grammar-extract tests/native_probe.py
```

It uses the delivered interpreter and disposable roots. To deliberately record a
new native observation, the supplied fixture documents:

```bash
bash tests/devenv.sh shell -- strictdoc-grammar-extract tests/native_probe.py --output evidence/native-observations.json
```

Native smoke/probe evidence covers only the behavior it exercised. Its RPC-array
partial publication and named-role cycle observations are gaps to fix, not
alternate definitions of atomicity or DAG validity.

## Proposed path from the DSL to validation

The authoring function in [canonical recommended.nix](recommended.nix) takes
`{ grammar, schema, constraint }`. Current public setup supplies `grammar`. The
isolated prototype supplies the proposed `schema` and `constraint`; no installed
import path for those two is claimed here.

This **complete prototype loading expression**, saved beside the canonical
files, makes those inputs concrete. It uses the same imports as
[evaluate.nix](authoring-prototype/evaluate.nix):

```nix
{ lib, grammar }:
let
  dsl = import ./authoring-prototype/dsl.nix { inherit lib grammar; };
  model = import ./recommended.nix {
    inherit grammar;
    inherit (dsl) schema constraint;
  };
in
builtins.deepSeq model.normalized {
  inherit (model) normalized rendered;
}
```

`model.elements` and `model.views` are authoring handles. Serialize only
`normalized` and `rendered`. `normalized.grammar` is the checked native element
list; `normalized.semanticTypes` carries the identified types/defaults;
`normalized.bundle` contains declaration, rule and view lists. `rendered` is
actual native grammar text from the existing renderer. See
[public-shape.md](authoring-prototype/public-shape.md) for the evaluated return
shape.

For a **bounded prototype evaluation from the repository root**, after these
files are published, run the following commands. They explicitly apply the
function-valued entrypoints with `--arg libPath` and `--arg grammarPath`.
Default parameters alone do not make `nix-instantiate` apply a function. The
library path is the local nixpkgs library recorded in the producer evidence; it
must already exist. If using another compatible local library, supply its path
and record that different input identity.

```bash
nix-instantiate --eval --strict --json \
  fixtures/strictdoc-semantic-library/contract/gate2/authoring-prototype/evaluate.nix \
  --arg libPath /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib \
  --arg grammarPath ./packages/strictdoc-grammar/lib \
  > /tmp/strictdoc-gate2-evaluated.json

nix-instantiate --eval --strict --json \
  fixtures/strictdoc-semantic-library/contract/gate2/authoring-prototype/controls.nix \
  --arg libPath /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib \
  --arg grammarPath ./packages/strictdoc-grammar/lib \
  > /tmp/strictdoc-gate2-control-results.json
```

These commands force native lowering/check/render and the Nix controls, writing
fresh scratch results rather than replacing retained evidence. They do not run
the Python helpers, invoke a semantic process backend or start Scribe. The
documentation workflow checked the command paths and arguments against the
supplied entrypoints; it did not execute these publication-layout commands.

```text
Ordered fields + keyed declarations + named constraints
                         |
                 proposed lowering
                   /           \
          native grammar       semantic types, rules, configuration
                 |                      |
      existing check/render       proposed common JSON invocation
                 |                      |
          generated SGRA         enabled implementation(s)
                                        |
                              structured validation report
```

Native lowering must continue through the existing normalized grammar
check/emission path. Semantic metadata travels separately; arbitrary
type/default/constraint keys are not accepted by the current native field
schema. Declaration handles lower to finite contextual identities, not
serialized recursive builders or Nix closures.

For example, FLAG retains Boolean meaning while native documents carry canonical
strings `false` or `true`. Metadata must identify the field and its codec,
requiredness, multiplicity and version/content identity. A backend may decode
native values or operate on their encoding; either route must honor the same
type contract. A second runtime graph containing Booleans is unnecessary. The
[semantic-type contract](interface.md#semantic-types-and-native-representation)
specifies the metadata and native string-list representation; production
transport remains unimplemented.

The common JSON boundary carries configured rule contracts, candidate and
required before/baseline inputs, metadata and implementation bindings. A backend
implements the named meaning or explicitly rejects unsupported operations.
Shipped helpers and independently supplied tools use the same boundary. Consumer
Python/Rego need not be translated into a universal expression language.

Rule results distinguish `satisfied`, `violated`, `blocked` and `error`, retain
evidence/locations/causes and account for every invoked rule exactly once.
Protocol success can contain a semantic violation. Missing, duplicate or
malformed results are errors. Full evaluation is the initial reference; later
incremental behavior must match it on identical effective inputs.

Keep the retained Python/rustworkx recommendation with native StrictDoc reuse.
OPA remains an optional adapter, supported by the retained experimental
evidence. Cozo is an experimental alternative, not a selected or qualified
integration. Install dependencies only for enabled implementations; enabling
graph rules must not pull in all experiment runtimes. The
[historical backend recommendation](recommendation.md) retains comparison
evidence, but its old authoring/lifecycle syntax is superseded by the
[scope reconciliation](scope-reconciliation.md). Historical experiments and
later interpreter/rustworkx pairing retain their original versions and
limitations; neither is new Scribe enforcement evidence.

## Proposed creation-only defaults

Defaults materialize authored values before final validation. They fill absent
fields on newly created records only. They do not silently backfill existing
documents during loading, checking or editing, and they are not Nix
module-option defaults such as `mkDefault`.

Canonical declaration fragment:

```nix
s.field.boolean "FLAG" {
  required = true;
  default = s.default.literal false;
}
```

That is a Boolean default. A string field's literal `"false"` is a different
typed value. Literal `""` is also a real string value, not absence. Defaults and
constraints refer to the same semantic field definition.

A script can obtain a display author name from Git configuration. Keep this
separate from the neutral FOO/BAR/BAZ grammar and repository protection policy.
The following **independently complete consumer declaration** gives NOTE an
explicit UID and a defaulted AUTHOR_LABEL string. All executable/script paths
are configured absolute paths, and `identityDirectory` is the configured
checkout directory:

```nix
{ grammar, schema, pythonExecutable, providerScript, gitExecutable, identityDirectory }:
let
  g = grammar.dsl;
  s = schema;
  uid = g.field.required (g.field.str "UID");
in
s.grammar "identity-example" (_: {
  elements.NOTE = _self: {
    fields = [
      uid
      (s.field.string "AUTHOR_LABEL" {
        required = true;
        default = s.default.script {
          argv = [ pythonExecutable providerScript gitExecutable identityDirectory ];
          timeoutMs = 1000;
        };
      })
    ];
  };
})
```

The exact proposed default protocol is
[sdoc-default/v1](interface.md#creation-time-defaults), separate from semantic
evaluation. It sends one request on stdin with `protocol`, `requestId`,
`candidatePreparationId`, `record`, `field`, `semanticTypesDigest` and `config`.
Success returns those protocol/request identities plus `status = "ok"` and typed
`value`; failure returns `status = "error"` and `{ code; message; }`. The host
validates the envelope and referenced field type.

**Complete illustrative provider script**, stored at `providerScript` and
invoked by the argv above. This implements the proposed response envelope; it
has not been run as a creation default. It reads the host-validated request,
invokes the configured Git executable and emits one JSON response:

```python
import json
import subprocess
import sys

request = json.load(sys.stdin)
if request["protocol"] != "sdoc-default/v1":
    raise ValueError("unsupported default protocol")

response = {
    "protocol": "sdoc-default/v1",
    "requestId": request["requestId"],
}
try:
    result = subprocess.run(
        [sys.argv[1], "config", "--null", "--get", "user.name"],
        cwd=sys.argv[2],
        check=True,
        capture_output=True,
        timeout=0.75,
    )
    if not result.stdout.endswith(b"\0") or result.stdout.count(b"\0") != 1:
        raise ValueError("expected one NUL-terminated Git value")
    value = result.stdout[:-1].decode("utf-8")
    response.update(status="ok", value=value)
except (OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
    response.update(
        status="error",
        error={"code": "git-identity", "message": str(error)},
    )

json.dump(response, sys.stdout, ensure_ascii=False)
sys.stdout.write("\n")
```

Git's NUL terminator lets the wrapper preserve a successful empty value without
trimming authored whitespace. An explicitly configured empty name produces a
success response like this **illustrative JSON**, not an executed result:

```json
{
  "protocol": "sdoc-default/v1",
  "requestId": "identity-1",
  "status": "ok",
  "value": ""
}
```

A failed lookup instead produces an error response of this exact shape:

```json
{
  "protocol": "sdoc-default/v1",
  "requestId": "identity-1",
  "status": "error",
  "error": { "code": "git-identity", "message": "Git identity lookup failed" }
}
```

The actual message comes from the caught failure. Both responses complete the
protocol with exit zero; the error response still refuses preparation. Nonzero
exit, timeout, malformed/extra output, a mismatched request ID, missing value or
wrong type also refuses preparation. Empty stdout is failure, not successful
`""`. Runtime packaging must provide absolute paths and dependencies only for
enabled providers; passing raw Git stdout directly to the runner does not
implement this JSON contract.

AUTHOR_LABEL is authored data, not authenticated actor identity. Acquisition
runs during candidate preparation, never Nix evaluation. No backend call, SSH
key or approval policy is part of this example.

| Final creation input                              | Required behavior                                                 |
| ------------------------------------------------- | ----------------------------------------------------------------- |
| FLAG absent, Boolean false default                | Materialize false, then validate.                                 |
| FLAG explicitly false                             | Preserve false; do not run its provider.                          |
| String explicitly empty                           | Preserve the value; field/native validity is a separate question. |
| Explicit value is invalid                         | Report failure; do not replace it with a default.                 |
| Provider successfully returns empty string        | Preserve typed empty value; it is not failed acquisition.         |
| Provider fails, times out or emits malformed data | Operational error; invent no value.                               |
| Required field remains absent                     | Validation rejects the candidate.                                 |
| Existing record lacks a defaulted field           | Do not backfill it.                                               |

Apply ordered explicit operations first, then resolve defaults for final absence
on surviving newly created records. In the separate consumer above,
`create NOTE-1; set NOTE-1.AUTHOR_LABEL="Ada"; set NOTE-1.AUTHOR_LABEL=""` ends
with an explicit empty value and must not run its provider. Creation followed by
an explicit unset leaves the field eligible if it remains absent. Creation
followed by deletion runs no defaults. Editing, moving or renaming an existing
record does not make it newly created.

Require construction identifiers such as UID explicitly. Do not acquire an early
hidden default to make a later operation resolve. Later explicit assignments,
including false and empty values, must never be overwritten.

Resolve providers once per prepared candidate. A real write must not run a
hidden dry-run and replay the mutations/providers. A separate later CLI
invocation is a new preparation and may acquire a different Git name. There is
no advertised coupling between default providers and semantic backends.

Current source limitation: native `add_node` rejects every explicit empty string
and missing required construction fields. Passing a successful empty default
through it unchanged is not yet supported. The future implementation must
reconcile construction and serialization with this contract; the documentation
cannot turn absence into empty or promise current support.

## Proposed atomic ordered batches

One invocation supplies an ordered operation list and validates its final
candidate. The handoff's command shape `scribe --create ... --edge ...`
illustrates the direction only; it is not today's parser. A single write is a
one-operation batch. JSON-RPC arrays currently dispatch independent writes and
do not provide this atomic boundary.

Use the tutorial's forest, an empty protection baseline and fresh candidates:

| Ordered operations in one future invocation              | Final-state expectation                                            |
| -------------------------------------------------------- | ------------------------------------------------------------------ |
| Create BAR M; add M Parent P=F0; add M Child Q=F2        | Accept complete M despite transient missing endpoints.             |
| Create M; add only P=F0                                  | Reject Q count 0; publish no M.                                    |
| Existing M P=F0/Q=F2: remove Q=F2; add Q=F1              | Accept final single Q; reversed add/remove order also passes.      |
| Existing open F2 with F1a R=F2a: set F2 closed           | Reject affected unchanged R.                                       |
| Same base: remove that R, then close F2                  | Accept if all other rules hold.                                    |
| Existing X below F1 with F1a R=X: move X under closed F2 | Reject the now-hidden unchanged R.                                 |
| Remove references to isolated I0, then delete I0         | Accept only if final native and preservation checks permit it.     |
| Move a document and edit its content                     | Validate proposed destination/membership and final bytes together. |

Create-then-edge must resolve a record created earlier in the same invocation.
Arbitrary forward references are not promised. Syntax/type/existence checks
still apply where needed, but final graph invariants must not reject a transient
zero/two endpoint count. Full validation does not imply rewriting every document
or rebuilding the whole graph after every operation.

The shared path is:

```text
capture stable base → privately apply ordered operations → creation defaults
→ identify exact candidate and effective inputs → full native validation
→ configured semantic validation → dry-run report OR publish that candidate
```

Dry-run uses the same preparation and full validation, stopping before
publication. It may create scratch files, run default scripts and populate
derived caches. Publication consumes the exact validated bytes, paths and
deletions; it does not replay operations. A stale base refuses publication and
requires fresh preparation/evaluation. Ordinary rejection discards private
state. Recovery is reserved for publication failure: restore prior state or
report recovery-required and block further writes. No crash-atomic multi-file
guarantee follows from the current restore helper.

Validators read fixed authoritative candidate/baseline inputs and may write
derived caches or scratch. A cache for a rejected candidate may remain under
that candidate's identity; it cannot become accepted state. Cache identities
must include the inputs each computation depends on, and cold/warm results must
agree. Read-only JSON alone does not isolate arbitrary host access.

The [source-only runtime audit](findings.md#new-public-source-facts-and-limits)
details current gaps: per-operation/node checks, touched-document reparsing,
move outside the write boundary, mutable held graph and stale indexes, missing
final base check, repeated rendering during save and incomplete recovery
guarantees. These findings require implementation and qualification; they are
not new runtime tests.

Future qualification must establish public Nix-to-Scribe wrong-target refusal
with valid FOO and independent BAZ controls; unchanged files/observable state
and reload after rejection; complete native union-DAG checks; final-state batch
behavior; defaults/dry-run parity; and exact-candidate publication/recovery. The
[closing plan](closing-plan.md#review-coverage) supplies the qualification
scope. The
[shared candidate contract](interface.md#one-prepared-candidate-validation-and-publication)
defines the preparation/publication boundary.

A later consumer-selected staged-tree check remains separate. Refusal there
leaves the user's already edited index/worktree alone. It does not undo an
earlier Scribe publication or create a public multi-call transaction lifecycle.

## What the evidence establishes

The supplied final [evidence record](authoring-prototype/evidence.md) reports
**57 Nix controls true** and **110 bounded synthetic Python helper controls
passed**. This documentation workflow inspected the source, controls and
recorded results; it did not rerun the prototype or start Scribe. The tutorial's
diagnostic sentences and tables remain authored explanations rather than
captured output.

The [review disposition](authoring-prototype/review-disposition.md) records four
bounded corrections: compound predicates retain nested view inputs and
validity/singleton dependencies; result validation checks concrete NodeRef
findings and integer locations; both target entries resolve full model-qualified
identities; and required known native-DAG definitions retain their meaning
through composition edits. The result checker is not a general production
subject/coordinate schema, the input prerequisite is not a complete native
snapshot validator, and the native-contract guard does not validate arbitrary
custom-contract compatibility. Generic predicate execution remains
unimplemented.

The unchanged independent review scripts replayed against the corrected
prototype. [Review regressions](authoring-prototype/review-regressions.json)
records **13 Python checks passed, zero failed**, including an independent
oracle over **162 supplied-forest path combinations**. Independent Nix replay
rejects removal of a compound's required forest and replacement of the required
native check by an always-true predicate. These are composition and
synthetic-helper controls, not native DAG execution or Scribe acceptance.
Canonical constructors and normalized/rendered reference artifacts are
unchanged. Earlier scripts/results retain their historical provenance; the
corrected replay records their source digests separately.

| Evidence level                     | What was established                                                                                                                        | Limit                                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Source inspection                  | Current public interfaces and candidate/default integration gaps                                                                            | No new runtime behavior follows from source reading.                                                      |
| Nix lower/check/render             | Forced finite normalized output, actual native grammar check/render, typed fields/default option shapes, references and checked composition | More than static parsing; rendered SGRA was not parsed by StrictDoc or loaded into Scribe.                |
| Synthetic Python helpers           | Two local target algorithms agree; counts, blocked singleton paths, supplied-forest traversal, Boolean codecs and result accounting         | No generic predicate interpreter, native forest construction/validation or all-role DAG implementation.   |
| Proposed common process invocation | Request/result/default envelopes are specified in [interface.md](interface.md)                                                              | No registration or process-transport integration executed.                                                |
| Real Scribe integration            | Remains future qualification                                                                                                                | No real default script execution, ordered batch mutation, isolation, exact publication or recovery proof. |

Inspect [evaluated.json](authoring-prototype/evaluated.json),
[control-results.json](authoring-prototype/control-results.json) and
[runtime-results.json](authoring-prototype/runtime-results.json) with the
[design and limits](authoring-prototype/design.md). Python uses synthetic model
inputs and a supplied valid forest. Labels B01/B02 describe final snapshots
only; they do not execute the operations of a batch. The two target entries are
local “shipped-style” and “independent” algorithms, not installed
implementations. Their producer IDs differ intentionally while contextual
results agree.

Preservation, field endpoint resolution and virtual union-DAG decisions are
contract examples. Typed script option validation does not execute a default
provider. The new Git wrapper above is teaching code for the proposed envelope,
separate from the canonical probe and its counts.

Historical backend experiments remain in the
[retained recommendation](recommendation.md); the later runtime pairing
establishes imports and synthetic graph compatibility, not native
parser/validator or Scribe enforcement. The [current findings](findings.md) and
[C1–C4](interface.md#c1c4-and-later-implementation-entry-conditions) retain the
missing integration qualifications.

Remaining review choices concern constructor vocabulary, key/identity escaping
and whether to expose the generic predicate IR now. Cross-language digest
canonicalization and exact runtime operand schemas require later contract
freezing. These do not reopen Boolean intent, creation-only defaults or
one-invocation final-state batches. The packet stays at Gate 2 review; it does
not declare Gate 2 passable or authorize production work.
