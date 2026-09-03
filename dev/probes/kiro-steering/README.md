# Steering `inclusion` probe fixtures

The instruments behind
[`packages/kiro-cli/docs/steering-inclusion.md`](../../../packages/kiro-cli/docs/steering-inclusion.md).
Dev-only: nothing here is exported from the flake or referenced by a build.

They exist because the CLI's steering behavior diverges from the vendor's
IDE-oriented documentation in two places, and **both divergences are silent** —
no error, no log line, nothing model-visible. Only a fixture with
distinguishable markers tells you what actually loaded, and re-deriving one
costs far more than reading one.

Measured 2026-09-03 against `kiro-cli` 2.21.0 / KAS 0.46.1.

## The fixture

Every document carries a unique `SENTINEL_*` marker, so "did this load" is a
string-exact question rather than a judgement call.

| File                 | Shape under test                           | Expected            |
| -------------------- | ------------------------------------------ | ------------------- |
| `s-always.md`        | `inclusion: always`                        | loads every turn    |
| `s-manual.md`        | `inclusion: manual`                        | never loads in CLI  |
| `s-auto.md`          | `inclusion: auto` + `name` + `description` | loads on disclosure |
| `s-fm-trailcomma.md` | multi-line flow array, trailing comma      | **degrades**        |
| `s-fm-clean.md`      | multi-line flow array, no trailing comma   | **degrades**        |
| `s-fm-inline.md`     | inline `["a"]`                             | correct             |
| `s-fm-scalar.md`     | scalar `"a"`                               | correct             |
| `s-fm-block.md`      | block sequence `- "a"`                     | correct             |
| `s-fm-match.md`      | scalar pattern that DOES match             | loads on read       |

**Every `s-fm-*` pattern except `s-fm-match.md`'s deliberately points at a file
that does not exist** (`**/nope-xyzzy.json`). That inverts the test into a clean
negative control: a correctly-parsed `fileMatch` document must NEVER inject. If
its sentinel shows up anyway, its frontmatter failed to parse and it silently
degraded to `always` — which is the whole finding. Do not "fix" those patterns
to match a real file; that destroys the discriminator.

`s-fm-match.md` is the deliberate exception, and the only one: it uses a shape
already measured as correct and a pattern that DOES match, so it can prove the
`fileMatch` machinery ran at all.

`target-match.json` is the file `s-fm-match.md` matches on; `src/plain.txt` is a
second readable file that matches nothing. Their contents do not matter; being
readable does.

**`s-fm-match.md` was added after the measured run and has NOT itself been
exercised.** It is the instrument for P4 below, not a recorded result. Every
other row in the table above was measured.

## Reproducing

The fixture is stored as a plain `steering/` directory rather than a nested
`.kiro/steering/`, so assemble a scratch workspace rather than running in place:

```bash
RIG="$(mktemp -d)"
mkdir -p "$RIG/.kiro"
cp -r dev/probes/kiro-steering/fixture/steering "$RIG/.kiro/steering"
cp -r dev/probes/kiro-steering/fixture/src "$RIG/src"
cp dev/probes/kiro-steering/fixture/target-match.json "$RIG/"
git -C "$RIG" init -q && git -C "$RIG" add -A
cd "$RIG"
```

`git init` is not decoration — an untrusted workspace silently drops workspace
steering while keeping global steering, so a rig that is not a repository
produces a clean-looking false negative.

Then run the three probes. A cheap model at low effort is correct here: these
are enumeration questions, and a stronger model will "helpfully" work around a
dead end and mask the finding.

```bash
# P1 — what is auto-injected. Expect: ALWAYS yes; every fm-* sentinel NO.
#      Any fm-* sentinel present == that shape degraded to always.
kiro-cli chat --no-interactive --trust-all-tools --model gpt-5.6-luna --effort low \
  'List every SENTINEL_ token visible in your context. Do not read any files.'

# P2 — manual reachability + the pool disclose_context serves, in one shot.
kiro-cli chat --no-interactive --trust-all-tools --model gpt-5.6-luna --effort low \
  'Call disclose_context with name="s-manual". Do not read any files. Report the
   tool error verbatim, then list the exact set of names disclose_context offers.'

# P3 — positive control for P2. Without this, P2 proves nothing.
kiro-cli chat --no-interactive --trust-all-tools --model gpt-5.6-luna --effort low \
  'Call disclose_context with name="s-auto", then report SENTINEL tokens you received.'

# P4 — positive control for P1. Proves the fileMatch machinery RAN rather than
#      never firing. Unverified — see the note above.
kiro-cli chat --no-interactive --trust-all-tools --model gpt-5.6-luna --effort low \
  'Read target-match.json, then list every SENTINEL token visible in your context.'
```

## Reading the result

- **P1** is the `fileMatch` verdict. `SENTINEL_ALWAYS` present and every
  `SENTINEL_*` from an `fm-` document absent is the correct outcome. A present
  `SENTINEL_TRAILCOMMA` or `SENTINEL_CLEAN` reproduces the degrade. Note what P1
  alone CANNOT tell you: a correctly-scoped document that stays absent looks
  identical to one whose scan never ran, since this probe reads nothing. That
  ambiguity is what P4 exists to close.
- **P4** should surface `SENTINEL_MATCH`, and still no other `fm-` sentinel.
  That separates "scoping works" from "scoping never executed".
- **P2** should fail with
  `No skill or auto inclusion steering file found with name "s-manual"`, and the
  "Available items" list should contain `s-auto` and no `s-manual`. The error
  text naming only skills and auto steering is the point — the pool excludes
  `manual` by construction.
- **P3** must succeed and return `SENTINEL_AUTO`. If it fails too, the rig is
  broken and P2's failure means nothing.

P2 without P3 is the classic trap: an unreachable name and a broken rig produce
identical output.

## Why these files are formatter-excluded

`treefmt.nix` and `checks/markdown-scan.nix` both skip
`dev/probes/kiro-steering/fixture/`. The YAML shape IS the experiment — prettier
would normalize `s-fm-clean.md` and `s-fm-trailcomma.md` into a passing shape
and silently delete the finding. If you move or rename this directory, update
both exclusions and this paragraph together.
