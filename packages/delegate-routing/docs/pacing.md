# Saved Reader observations

`normalize(snapshot, now)` turns saved Reader output into allowance records for
ranking. It runs no Reader command and reads no clock, so the same snapshot and
Unix-second `now` always produce the same result. Collecting Reader output,
deciding what a vendor means by its status, and ranking candidates are separate
layers.

## Input and output

A snapshot has three parts:

- `routes`: the model identities configured in CPA. Each route has a canonical
  `id`, a nullable `maker`, and the served `model` spelling.
- `pools`: a map of pool registrations. Each registration names the exact
  `readerPool` it accepts and a `limits` map. A limit names its positive
  `capacity`, canonical model `ids`, `gate` or `pace` role, and the exact Reader
  `window` key that supplies it. Two limits in one pool cannot claim the same
  window.
- `readers`: a map keyed by pool name. Each value is one saved command result:
  an integer `exit` and the Reader's JSON `stdout`. On success, that JSON names
  its `pool` and carries a `windows` map.

A window carries `remainingPercent` and `usedPercent`, which must be finite
percentages between 0 and 100 and together total 100; a positive
`windowSeconds`; an optional `enforced` boolean; and `resetsAt`, which is an ISO
8601 timestamp with an offset or null. Null is valid only for an idle window or
a gate with remaining allowance above zero. An idle window is exactly 0 used and
100 remaining.

`normalize` returns a `Normalized` object:

- `asOf` is the supplied Unix time.
- `routes` is copied unchanged.
- Each pool contains every configured limit, sorted by its id, and a
  `scopeResolved` flag. The flag is true only when the pool's capture parsed,
  named the registered Reader pool, and contained no window outside its
  registrations.
- Each limit keeps `capacity`, `models`, and `role`; adds its configured id; and
  supplies `remaining`, `windowSeconds`, `enforced`, `naturalResetAt` as Unix
  seconds, `status`, and a nullable `reason`. The input `window` key is not
  copied.

The status is `valid`, `stale`, `invalid`, or `missing`. A valid enforced limit
has no reason. Other results carry a local reason code so a maintainer can see
why ranking cannot use the allowance without seeing Reader errors or stack
traces.

## The three safety rules

1. A window that fails validation is invalid as a whole. Its positive allowance
   is discarded rather than partly rescued.
2. A window that already proves `remainingPercent` is zero keeps `remaining: 0`
   even when another field is broken. A broken window never reports a positive
   allowance.
3. Every configured limit always has a result. Missing captures, unreadable
   JSON, a nonzero exit, a pool mismatch, a missing window, and an invalid
   window become `missing` or `invalid` observations with reasons. Only a
   configuration error raises: unknown model ids in registrations and duplicate
   window registrations are rejected before captures are read.

## Vendor modules

This core stops at evidence that every vendor can share. A later per-vendor
Reader module decides what the vendor's status vocabulary means before handing
the normalizer an `enforced` value. For example, CPA may translate overspend
into exhaustion and Codex may translate a null status; those meanings do not
belong here. The core also does not launch Readers, attribute accounts, or rank
routes.

## Add a behavior case

Create `packages/delegate-routing/checks/pacing/cases/<name>/`, where the name
states the behavior and the wrong implementation it catches. Put a complete
`input.json` there and exactly one expected file:

- `expected.json` contains the complete normalizer output.
- `expected-error.json` contains `{ "validationError": "..." }` for a
  configuration the boundary must refuse.

The runner discovers every case directory, parses both files once, and compares
the whole result. Add a Hypothesis test in `run_cases.py` only when one behavior
spans many inputs. Build the check with:

```bash
flock /tmp/nat-vm-spike.lock systemd-run --user --scope -q -p CPUQuota=200% -p MemoryMax=6G nix build --max-jobs 1 --cores 2 --no-link -L .#checks.x86_64-linux.delegate-routing-observation-normalize
```

This small input has one 40-unit pace limit with half its allowance left:

```json
{
  "now": 1794447300,
  "snapshot": {
    "pools": {
      "budget": {
        "limits": {
          "allowance": {
            "capacity": 40.0,
            "models": ["canonical-a"],
            "role": "pace",
            "window": "7d"
          }
        },
        "readerPool": "reader"
      }
    },
    "readers": {
      "budget": {
        "exit": 0,
        "stdout": "{\"pool\":\"reader\",\"windows\":{\"7d\":{\"enforced\":true,\"remainingPercent\":50,\"resetsAt\":\"2026-11-19T01:35:00Z\",\"usedPercent\":50,\"windowSeconds\":604800}}}"
      }
    },
    "routes": [{ "id": "canonical-a", "maker": null, "model": "served-fable" }]
  }
}
```

Its whole expected output is:

```json
{
  "asOf": 1794447300,
  "pools": {
    "budget": {
      "limits": [
        {
          "capacity": 40.0,
          "enforced": true,
          "id": "allowance",
          "models": ["canonical-a"],
          "naturalResetAt": 1795052100,
          "reason": null,
          "remaining": 20.0,
          "role": "pace",
          "status": "valid",
          "windowSeconds": 604800.0
        }
      ],
      "scopeResolved": true
    }
  },
  "routes": [{ "id": "canonical-a", "maker": null, "model": "served-fable" }]
}
```
