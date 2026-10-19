# Extracted facts: the contract

> **Last verified:** 2026-10-18 — owners commit forked `extracted.json`; Linux
> carries make other systems follow; owner checks use `mkOwnerCheck`; Go owners
> extract with `goTestExtract` over the generic `goTest`; facts and
> reconciliation share the private redact classifier.

A fact is something the repo measured about a tool it packages: a settings key,
a model id, a hook trigger, a byte limit, whether a patch applies. Facts are
measured per platform, combined by declared rules, and read by consumers that
say what they depend on. This file is the contract every piece of that machinery
is written against. Per-owner code supplies data and an extractor; it never
contains merge, combine or platform logic. A check enforces that.

## Files per owner

| File                                        | Written by                               | Holds                                                                    |
| ------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------ |
| `packages/<owner>/extracted/extracted.json` | `regenerate`, on each host that extracts | every system's raw measured value tree, forked only where systems differ |
| `packages/<owner>/extracted/facts.json`     | the extractor's author                   | declarations: one row per key, type and source                           |
| `packages/<owner>/extracted/decisions.json` | a human, dated                           | exceptions: how a key combines when systems differ                       |

The aggregate is never committed per owner. `lib.extracted.index` writes it from
the inputs above; absent decisions default to `{}`.

`<system>` is one of `config/systems.nix`.

## The committed file (`extracted.json`)

One tree for every system in `config/systems.nix`. Where the systems agree a
value appears once. Where they differ, the smallest differing node is replaced
by a fork, `{"__platforms": {"<system>": value, ...}}`; a system absent under
`__platforms` lacks that key. Attribute sets are compared per key; any other
value, arrays included, forks whole. An owner measured on one host commits its
raw unforked, and every system's projection is that raw.

```json
{
  "rolloutFeatures": ["standalone_toolbox", "v3_prompt"],
  "rolloutPatchability": {
    "v3_prompt": {
      "patchable": false,
      "unmatchedSites": {
        "__platforms": { "aarch64-darwin": 2, "x86_64-linux": 1 }
      }
    }
  }
}
```

`lib/extracted/platforms.nix` (builtins only) owns the shape:

- `merge { "<system>" = raw; }` → the committed tree. Measured data holding the
  key `__platforms` anywhere, inside lists included, throws naming the path.
- `project merged system` → that system's raw. A fork mixing `__platforms` with
  other keys, a fork value holding `__platforms`, or a tree with no side for the
  system throws.
- `carry { merged; fresh = { "<system>" = raw; }; systems; }` → the committed
  tree with `fresh`'s sides replaced. When the base system `x86_64-linux` is
  fresh, every other system keeps its own fork values and follows the fresh raw
  at every unforked node, new and removed keys included, so a base bump
  introduces no divergence; a forked parent the fresh raw removes or retypes
  keeps the follower's whole committed value. When another system is fresh,
  every other system keeps its exact projection, so a new difference becomes a
  fork. When the base is fresh and some system is not, the base is the only
  fresh system; otherwise `carry` throws.

Nothing outside `lib/extracted/` and `checks/extracted/` reads the file or its
forks.

## Keys

A key is a dotted path into the raw JSON tree: `settingKeys`,
`rolloutFeatures.<name>.state`, `cli.commands.<name>.flags`. The segment
`<name>` matches any attribute name at that depth, so one declaration covers
every child and a new child inherits it. A path that names a list element is not
a key: a list is a leaf. Attribute names containing dots, such as those in
`settings.paths`, require an opaque `object` declaration for their parent.

## Declarations (`facts.json`)

```json
{
  "settingKeys": { "type": "set", "source": "host-run" },
  "rolloutFeatures.<name>.state": { "type": "string", "source": "static" },
  "rolloutUnmatched.<name>": {
    "type": "count",
    "source": "static"
  },
  "lastLiveRun": { "type": "string", "source": "live", "systems": [] }
}
```

| Field     | Values                                                        | Meaning                                                                                                                        |
| --------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `type`    | `bool` `count` `string` `set` `list` `object`                 | fixes validation and the default combine rule                                                                                  |
| `source`  | `static` `host-run` `live`                                    | `static`: same answer given the artifact; `host-run`: must execute on the host; `live`: needs a login or network, operator-run |
| `systems` | list of systems, default every system in `config/systems.nix` | which raws must carry a value for this key; `[]` for `live`                                                                    |

`set` is a list of strings compared without order. `list` is ordered. `count` is
a non-negative integer. `object` is opaque and only compared whole.

## Decisions (`decisions.json`)

```json
{
  "rolloutUnmatched.<name>": {
    "combine": "per-platform",
    "reason": "the patcher needs the host's own count; patchable is derived per host",
    "decided": "2026-10-10"
  },
  "models": {
    "combine": "intersection",
    "ignore": ["kiro-internal-preview"],
    "reason": "the option enum must be valid on both platforms",
    "decided": "2026-10-10"
  }
}
```

| Field     | Required | Meaning                                                                 |
| --------- | -------- | ----------------------------------------------------------------------- |
| `combine` | yes      | one of the closed vocabulary below                                      |
| `reason`  | yes      | why; non-blank                                                          |
| `decided` | yes      | ISO date                                                                |
| `ignore`  | no       | set or list elements removed from every system's value before combining |

Combine vocabulary, closed: `equal`, `and`, `or`, `max`, `min`, `intersection`,
`union`, `prefer:<system>`, `per-platform`, `ignore`. Anything else is a
`bad-decision` failure. `and` and `or` apply to `bool`, `max` and `min` to
`count`, `intersection` and `union` to `set` and `list`, the rest to every type.
`ignore` as a combine drops the key from the aggregate entirely (it stays in the
raws). `per-platform` produces no combined value; consumers read per system.

Defaults when no decision row exists, by declared type:

| Type     | Default combine |
| -------- | --------------- |
| `bool`   | `and`           |
| `set`    | `intersection`  |
| `count`  | `equal`         |
| `string` | `equal`         |
| `list`   | `equal`         |
| `object` | `equal`         |

`equal` means the systems must agree or merge fails. That is deliberate: a
differing count or string is a decision, and the failure prints the row.

## `lib/extracted/facts.nix`

Needs only `lib`, like `reconcile`, so an option module can call it before
`pkgs` exists.

`declarations dir` reads the owner's required `facts.json` once for both `load`
and `hostRunOn system dir`. The latter selects owners with a `host-run` row
requiring that system, using the configured systems as the default for an
omitted `systems` field. The Darwin CI planner uses it without evaluating Darwin
checks on Linux.

### `load`

```nix
load {
  dir;                       # path: the owner's extracted/ directory
  secretHints ? {};
}
→ merge result
```

The only way to read raws. Reads `facts.json` and `extracted.json` (both
required: the absence of either throws when `load` is forced to weak head normal
form, naming the path) and `decisions.json` (optional, `{}` when absent), then
calls `merge` with every configured system's projection against every system in
`config/systems.nix`. A key a system's side lacks therefore fails as
`missing-system` for that system when its declaration requires it; a
declaration's own `systems` still narrows that. A fork's side for a system
outside `config/systems.nix` is never read.

### `merge`

```nix
merge {
  declarations;              # parsed facts.json
  decisions ? {};            # parsed decisions.json
  raws;                      # { "<system>" = <parsed raw tree>; }
  systems;                   # import ../../config/systems.nix
  secretHints ? {};          # passed to lib/redact/classify.nix per key
}
→ {
  aggregate = {
    "<key>" = {
      value;                 # combined; ABSENT for per-platform keys
      bySystem = { "<system>" = <raw value>; };
      type; source; combine; # as resolved
      failure;               # { kind; details; fix; } ONLY when value is
                             # absent because of a failure
    };
  };
  undeclared = [ "<key>" ];  # present in a raw, no declaration; informational
  failures = [ { kind; key; details; fix; } ];
}
```

`fix` is a ready-to-paste snippet: for `divergent` it is the complete
`decisions.json` row, keyed by the declared pattern, with every system's value
shown in `details`; for `declared-gone` it is "delete the declaration for
`<key>`". Pure evaluation cannot know today's date, so the generated row's
`decided` carries the literal placeholder `YYYY-MM-DD` and its `reason` is a
`TODO: <what to explain>`; `bad-decision` rejects both literals (a `reason` is a
placeholder only when, trimmed, it is exactly `TODO` or begins with `TODO:`), so
a row pasted unedited fails naming exactly the fields the human must fill.
`decided` must be an ISO `YYYY-MM-DD` date; its shape is checked, calendar
validity is not: the field is provenance, nothing reads it.

Failure kinds and when they fire:

| Kind                | Fires when                                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `divergent`         | systems disagree and the effective combine is `equal`                                                                                                       |
| `missing-system`    | a declared key is present in at least one system but absent from another its declaration requires                                                           |
| `declared-gone`     | a declared key is absent from every raw; `missing-system` does not also fire. Not for `systems = []`                                                        |
| `type-mismatch`     | a raw value does not fit the declared type                                                                                                                  |
| `bad-decision`      | unknown combine, a combine its key's type does not take, blank reason, missing or malformed date, `ignore` on a non-collection, a row for an undeclared key |
| `undeclared-secret` | an undeclared key that `classify` flags as credential-shaped                                                                                                |

Not failures: an undeclared key (listed in `undeclared`); a key that only `live`
systems would carry; wildcard children appearing or disappearing. A wildcard
child present on one system and absent on another is a disappearing child, not
`missing-system`; the aggregate is keyed by concrete paths, one entry per
matched child, and `prefer:<system>` takes the only value when the preferred
system lacks that child. A declaration pattern never hides a raw leaf: a leaf at
a prefix of a declared path is undeclared and is classified like any other.
`ignore` as a combine drops the key from the aggregate only; its raws are still
validated and `type-mismatch`, `missing-system` and `declared-gone` still fire.

### `children` and `get`

`get aggregate "<key>"` returns the combined value. `get` on a key without a
combined value throws naming the key, the failure and the fix: the entry's
`failure` (for `divergent`, the paste-ready `decisions.json` row), or for a
`per-platform` key the advice to read `bySystem` from the index, or add a
`decisions.json` row that combines it. A key absent from the aggregate
(undeclared, or `declared-gone`) throws naming the key and both remedies. There
is no fallback value.

`children aggregate "<pattern>"` reads a declared key pattern containing exactly
one `<name>` segment and returns `{ "<child>" = <combined value>; }` for its
matching concrete leaves. Matching requires the same number of dotted segments,
with every fixed segment equal. Each value is read through `get`, so a matched
per-platform or failed leaf throws with the same key, failure and remedy. No
matches returns `{}`: disappearing wildcard children are not a failure. A
pattern without exactly one `<name>` segment throws. Consumers use these readers
to read facts.

### `expect`

```nix
expect {
  aggregate;
  consumer = "delegate-routing";   # named in every failure
  needs = [
    { key = "tools"; contains = "invoke_sub_agent"; }
    { key = "steering.maxChars"; value = 50000; }
    { key = "hookTriggers"; }      # presence only
  ];
}
→ { failures = [ { kind = "expectation"; consumer; key; expected; actual; } ]; }
```

A consumer declares the facts its generated output was written against. When the
aggregate no longer satisfies a need, the consumer's own check fails, naming the
consumer, the key, the expected and the actual value. This is how "the harness
changed under the skill" surfaces.

### `index`

Needs `pkgs`. Takes `{ "<owner>" = merge-result; }` and writes one JSON per
owner plus `index.json` across owners, each key carrying `value`, `bySystem`,
`type`, `source`, `combine`. External readers (skills, CI scripts) read these
files; Nix consumers read the aggregate directly.

`checks.extracted-index` and the Darwin CI planner load the explicit
logical-name-to-directory map in `checks/extracted/owners.nix`. These names
identify its JSON files and index keys independently of owner directory names.
External readers build that attribute and read its files.

## Drift

`mkOwnerCheck { dir; name; package ? null; extracted ? { <host> = package.passthru.extracted; }; needs ? []; results ? {}; }`
in `lib/extracted/default.nix` loads an owner's facts, checks its optional
consumer needs and supplied annotation `results`, and compares each extraction.
`results.facts` and `results.consumers` are the builder's own surfaces; a
`results` that names either is refused, so a supplied `facts.failures = []` can
never silence a merge failure. `dir` names the committed facts directory; `name`
identifies the check and its `packages/<name>/extracted/extracted.json`
regeneration path, independently of that directory's physical location. An owner
whose extractions run on another host passes `extracted` itself: Kiro reads both
releases statically on Linux.

`mkDriftCheck { committed; extracted; name; results ? {}; sidecar; }` takes the
committed `extracted.json` as a path, its repository path as a string, and
`extracted = { "<system>" = derivation; }`. A derivation's `system` is the host
its extraction runs on. On host `S` the check compares every system whose
extraction runs on `S` with that system's projection of the committed file; a
static extractor may supply several systems, a host-run one only `S`, and a host
that runs none compares nothing. Every drifted system is reported, each naming
its side of the committed file, and the check fails once at the end.

Owner checks expose `passthru.regenerate`: run
`nix run .#checks.<host>.<name>-extracted.passthru.regenerate` from the
repository root to `carry` every extraction this host runs into the committed
file, format it, set its mode to 0644 and report the written path. A host that
runs every system's extraction rewrites the file from fresh raws alone. Linux
carries the other systems forward at every unforked node, and their own host's
check then validates their projection; any other host rewrites only its own
side, forming a fork wherever it now differs.

Owner update scripts use `regenCommand { name; }` to build and run that
regenerator on the current host.

A Go owner's `passthru.extracted` is
`goTestExtract { package; packagePath; testFile; }`: through `goTest` it joins
`testFile` and `go/nat_shared_test.go` (given the test's package clause) to
`packagePath` under the buildGoModule `package`'s `modRoot`, runs
`TestNatExtract` offline with the package's toolchain and vendor tree, and keeps
the object of surfaces the test writes to `$NAT_EXTRACT_OUT`.

## The guard

`checks.extracted-contract-guard` fails when any tracked file outside
`lib/extracted/` and `checks/extracted/` names `extracted/extracted.json` or
`__platforms`, reaches into `bySystem`, or defines a combine. Owners supply data
and extractors only.

## Fixtures (`checks/extracted/facts.nix`)

Eval-time cases in the style of `checks/extracted/reconcile.nix`, each naming
its refused input or its visible result, plus one derivation that asserts the
`divergent` message contains the paste-ready row.

1. Two systems agree: aggregate carries the value, no failures.
2. Differ with a rule: `set` intersection by default; `bool` and; `count` with a
   `max` or `min` decision; `bool` with `or`; `string` with
   `prefer:x86_64-linux`.
3. Differ without a rule: `divergent`, and `fix` is a complete decisions row.
4. New key, undeclared, not secret-shaped: no failure, listed in `undeclared`.
5. New key, undeclared, secret-shaped: `undeclared-secret`.
6. Declared key absent everywhere: `declared-gone`.
7. Type mismatch: a string where `count` is declared.
8. `per-platform`: no combined value; `get` throws with the reader remedy.
9. `expect`: a satisfied set and a failed set, failure names the consumer.
10. Wildcard declaration applies to every child, and a new child is covered. A
    disappearing child keeps its sole value even when the preferred system lacks
    it.
11. `bad-decision`: unknown combine; blank reason; row for an undeclared key.
12. `ignore` removes an element before intersection.
13. `missing-system`: declared for both, present in one.
14. `live` with `systems = []`: no system required, no failure; `get` on a
    divergent key throws and the entry carries merge's failure, and
    `extracted-facts-divergent-fix` evaluates that `get` in a dummy-store
    `nix-instantiate` to assert its message names the key and the row.
15. `load` (fixture directories under `checks/extracted/load/`): a key forked
    across both configured systems and one outside `config/systems.nix` (never
    read) merges clean with its decision applied; with Darwin's side lacking
    every key, each declared key fails `missing-system` naming it, and a
    `prefer:aarch64-darwin` decision is not a `bad-decision`. `load` on a
    directory without `facts.json`, or without `extracted.json`, throws. An
    unforked file whose declarations require only Linux loads without failures.
    A committed file with a fork, carried by a fresh Linux raw that adds a
    feature, loads clean and Darwin's projection holds the feature and keeps its
    fork; replacing only Linux's side instead fails `divergent`.

`checks/extracted/platforms.nix` pins the committed file: agreement stored once,
the smallest differing node forked, arrays forked whole, a key one system lacks,
a single raw left unforked, the merge/project round trip, the sentinel refused
in measured data (lists included) and in malformed forks, and `carry` following,
dropping, collapsing a fork, merging when every system is fresh, keeping a
removed or retyped forked parent whole, a Darwin carry leaving Linux as
committed and forming the fork a later Linux carry keeps, and refusing two fresh
systems while another is not.

`checks/extracted/drift.nix` runs `mkDriftCheck`'s script per case: a fork is
compared through the host's projection, a foreign-system extraction is skipped,
and every drifted system is named while a matching one is not. A case with
`regenerate` also reads the regenerate script's text, which must name each fresh
raw this host carries and omit the foreign one.
