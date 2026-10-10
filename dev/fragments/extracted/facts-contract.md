# Extracted facts: the contract

> **Last verified:** 2026-10-10 — initial contract. Nothing is migrated to it
> yet; `lib/extracted/facts.nix` and its fixtures are the only consumers.

A fact is something the repo measured about a tool it packages: a settings key,
a model id, a hook trigger, a byte limit, whether a patch applies. Facts are
measured per platform, combined by declared rules, and read by consumers that
say what they depend on. This file is the contract every piece of that machinery
is written against. Per-owner code supplies data and an extractor; it never
contains merge, combine or platform logic. A check enforces that.

## Files per owner

| File                                        | Written by                                   | Holds                                              |
| ------------------------------------------- | -------------------------------------------- | -------------------------------------------------- |
| `packages/<owner>/extracted/<system>.json`  | CI on that system, or Linux for static facts | the raw measured value tree for one system         |
| `packages/<owner>/extracted/facts.json`     | the extractor's author                       | declarations: one row per key, type and source     |
| `packages/<owner>/extracted/decisions.json` | a human, dated                               | exceptions: how a key combines when systems differ |

The aggregate is never committed per owner. `lib.extracted.index` writes it from
the three inputs above, and the drift check compares that output.

`<system>` is one of `config/systems.nix`. Today's single `extracted.json` is
the pre-contract shape; it keeps working through `mkDriftCheck` until its owner
migrates.

## Keys

A key is a dotted path into the raw JSON tree: `settingKeys`,
`rolloutFeatures.<name>.state`, `cli.commands.<name>.flags`. The segment
`<name>` matches any attribute name at that depth, so one declaration covers
every child and a new child inherits it. A path that names a list element is not
a key: a list is a leaf.

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
`bad-decision` failure. `ignore` as a combine drops the key from the aggregate
entirely (it stays in the raws). `per-platform` produces no combined value;
consumers read per system.

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
`pkgs` exists. Four functions.

### `merge`

```nix
merge {
  declarations;              # parsed facts.json
  decisions ? {};            # parsed decisions.json
  raws;                      # { "<system>" = <parsed raw tree>; }
  systems;                   # import ../../config/systems.nix
  secretHints ? {};          # passed to lib.runtimeValues.classify per key
}
→ {
  aggregate = {
    "<key>" = {
      value;                 # combined; ABSENT for per-platform keys
      bySystem = { "<system>" = <raw value>; };
      type; source; combine; # as resolved
    };
  };
  undeclared = [ "<key>" ];  # present in a raw, no declaration; informational
  failures = [ { kind; key; details; fix; } ];
}
```

`fix` is a ready-to-paste snippet: for `divergent` it is the complete
`decisions.json` row with every system's value shown in `details`; for
`declared-gone` it is "delete the declaration for `<key>`".

Failure kinds and when they fire:

| Kind                | Fires when                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `divergent`         | systems disagree and the effective combine is `equal`                                                               |
| `missing-system`    | a declared key has no value in a system its declaration requires                                                    |
| `declared-gone`     | a declared key is absent from every raw                                                                             |
| `type-mismatch`     | a raw value does not fit the declared type                                                                          |
| `bad-decision`      | unknown combine, blank reason, missing or malformed date, `ignore` on a non-collection, a row for an undeclared key |
| `undeclared-secret` | an undeclared key that `classify` flags as credential-shaped                                                        |

Not failures: an undeclared key (listed in `undeclared`); a key that only `live`
systems would carry; wildcard children appearing or disappearing.

### `get` and `getFor`

`get aggregate "<key>"` returns the combined value and throws, naming the key
and the fix, when the key is `per-platform`. `getFor system aggregate "<key>"`
returns that system's raw value for any key. Consumers use nothing else to read
facts.

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

## Drift

`mkDriftCheck` accepts, in addition to today's single `committed` and
`extracted`, per-system inputs: `committed = { "<system>" = path; }` and
`extracted = { "<system>" = derivation; }`. On host `S` it diffs every system
whose extraction derivation can build on `S`; a static extractor may supply
both. The message names the committed path for the system that drifted.

## The guard

`checks.extracted-contract-guard` fails when any tracked file outside
`lib/extracted/` and `checks/extracted/` reads a per-system raw path, reaches
into `bySystem`, or defines a combine. Owners supply data and extractors only.

## Fixtures (`checks/extracted/facts.nix`)

Eval-time cases in the style of `checks/extracted/reconcile.nix`, each naming
its refused input or its visible result, plus one derivation that asserts the
`divergent` message contains the paste-ready row.

1. Two systems agree: aggregate carries the value, no failures.
2. Differ with a rule: `set` intersection by default; `bool` and; `count` with a
   `max` decision; `string` with `prefer:x86_64-linux`.
3. Differ without a rule: `divergent`, and `fix` is a complete decisions row.
4. New key, undeclared, not secret-shaped: no failure, listed in `undeclared`.
5. New key, undeclared, secret-shaped: `undeclared-secret`.
6. Declared key absent everywhere: `declared-gone`.
7. Type mismatch: a string where `count` is declared.
8. `per-platform`: `get` throws, `getFor` returns each system's value.
9. `expect`: a satisfied set and a failed set, failure names the consumer.
10. Wildcard declaration applies to every child, and a new child is covered.
11. `bad-decision`: unknown combine; blank reason; row for an undeclared key.
12. `ignore` removes an element before intersection.
13. `missing-system`: declared for both, present in one.
14. `live` with `systems = []`: no system required, no failure.
