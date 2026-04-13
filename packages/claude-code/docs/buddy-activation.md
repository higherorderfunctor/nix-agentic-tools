## Buddy Activation Lifecycle

> **Last verified:** 2026-04-12 (commit 0f8ad25). If you touch
> the buddy activation script in `packages/claude-code/lib/mkClaude.nix`,
> the any-buddy worker invocation, the fingerprint scheme, or how
> the binary gets patched and this fragment isn't updated in the
> same commit, stop and fix it.

When a user configures `programs.claude-code.buddy = { ... }`
(canonical) or `ai.claude.buddy = { ... }` (fanout from
`modules/ai/default.nix`), an HM activation script runs on every
`home-manager switch`. It computes a fingerprint, compares to the
stored one, and on mismatch: copies the binary to a writable location,
runs the any-buddy worker, patches the salt into the binary, and
resets the companion field in `~/.claude.json`.

### Fingerprint inputs

The fingerprint is `sha256sum` of a newline-separated concatenation
of:

1. The store path of the claude binary (`cfg.package/bin/claude`)
   (so a claude-code version bump invalidates)
2. The resolved `$USER_ID` (from `userId.text` or
   `cat $USER_ID_FILE`)
3. `buddy.species`
4. `buddy.rarity`
5. `buddy.eyes`
6. `buddy.hat`
7. `shiny` flag (string "true" or empty)
8. `buddy.peak` (or empty when null)
9. `buddy.dump` (or empty when null)

Only the first 16 hex chars of the sha256 are stored. Stored at
`$XDG_STATE_HOME/claude-code-buddy/fingerprint`.

**If fingerprint matches, the update block is skipped via an
`if`/`fi` guard.** The entire update pipeline (binary copy,
salt patch, companion reset, fingerprint save) is gated so
re-running `home-manager switch` with unchanged config is fast.

**CRITICAL — do NOT use `exit 0` for the short-circuit.** HM
activation scripts are INLINED into a single outer bash script
(`$out/home-manager-generation/activate`) that runs under
`set -eu -o pipefail`. A bare `exit 0` inside any activation
block terminates the WHOLE activation — every subsequent hook
(including `home.file` writes for skills, plugin installs, and
the linkGeneration step) is silently skipped. Users observe
"activation succeeded" but skills never update on disk.

This bit us in commit (pending — the fix) after Task 2 of the
skills-fanout-fix plan: re-activation stopped at
`Activating claudeBuddy` with no error, and the stale Layout A
skills persisted because every post-buddy step was unreached.
Always use `if [ "$NEW_FP" != "$OLD_FP" ]; then ... fi` — never
`exit` for the fast path.

### Invalidation triggers

The fingerprint changes (triggering re-run) on:

| Trigger                                                   | Why                                   |
| --------------------------------------------------------- | ------------------------------------- |
| First activation                                          | No fingerprint exists yet             |
| Any `buddy.*` option change                               | Direct input to the hash              |
| `claude-code` version upgrade                             | Store path is an input                |
| sops-decrypted UUID file content change                   | `userId.file` read at activation time |
| Manual `rm $XDG_STATE_HOME/claude-code-buddy/fingerprint` | Forces re-run                         |

Explicitly NOT triggering:

- User manually edits the binary in the state dir (fingerprint only
  tracks inputs, not outputs)
- User manually edits `~/.claude.json` `companion` field (runtime
  state, not tracked)
- claude-code autoupdate (if enabled) replaces the store — would
  trigger, but our package pins via nix-update so autoupdate doesn't
  normally happen

### What the activation script does on re-run

1. **Resolve userId**: from `userId.text` (literal) or
   `userId.file` (sops path). File case uses `tr -d '\n\r'` to
   strip trailing whitespace. If file doesn't exist, errors out
   with a pointer to sops-nix ordering.
2. **Copy binary**: `mkdir -p $STATE_DIR`,
   `cp $STORE_BINARY $STATE_DIR/claude`, `chmod u+w`. The store
   binary is a Bun-compiled single-exec; the copy is the only
   mutable file in the state dir.
3. **Salt search**: `bun ${any-buddy}/src/finder/worker.ts
"$USER_ID" species rarity eyes hat shiny peak dump | jq -r .salt`.
   Worker brute-forces a 15-char salt that hashes (via wyhash under
   Bun) to the desired traits. Validates output is 15 chars matching
   `[a-zA-Z0-9_-]`.
4. **Patch the binary**: python3 binary-safe replace of
   `b'friend-2026-401'` with the new salt (3 occurrences in the
   compiled Bun binary). The marker is 15 bytes, the salt is 15
   bytes (constrained by the regex validation), so byte length is
   preserved. The script warns if the occurrence count is not
   exactly 3.
5. **macOS: re-codesign**: on Darwin, `/usr/bin/codesign --force
--sign -` re-applies an ad-hoc code signature after binary
   modification. Skipped on Linux.
6. **Reset companion**: if `~/.claude.json` exists, `jq 'del(.companion)'`
   through a temp file. Otherwise skipped (first-run case).
7. **Save fingerprint**: write the new 16-char hash to
   `$STATE_DIR/fingerprint`.

### Why the companion reset matters

`~/.claude.json` `companion` field is set by claude-code on first
hatch and cached across runs. It contains the buddy traits derived
from the current salt. If you change the salt (by changing buddy
options) but leave the cached companion alone, claude-code happily
keeps showing the OLD buddy because its runtime lookup hits the
cache before re-running the hash.

So the activation script MUST reset companion on every fingerprint
mismatch. Otherwise users think their config didn't take effect.

### Common failure modes

**"cannot coerce null to a string"** during activation eval:
`peakArg` or `dumpArg` was null and hit `"${null}"` interpolation.
Nix `or ""` doesn't catch null, only missing attributes. Fix is
explicit `if cfg.peak == null then "" else cfg.peak`. Landed in
commit 753ec43. If it recurs, check whether any other nullable
buddy option is being string-interpolated without a null guard.

**`programs.claude-code.buddy = null` despite `ai.claude.buddy`
being set**: the `ai.*` fanout block in `modules/ai/default.nix`
used to be gated on `mkIf cfg.enable` (where `cfg = config.ai`),
requiring `ai.enable = true` in addition to `ai.claude.enable`.
Users who only set `ai.claude.enable` got a silent no-op — the
buddy config was stored in the option but never fanned out.
Dropped the master switch in commit f2e911c. If it recurs, verify
the fanout block is NOT gated on anything except
`cfg.claude.enable`.

**Salt search returns a buddy that's not what you configured**:
hash-function mismatch between the worker and the runtime. Worker
runs under Bun (wyhash). Runtime must ALSO run under Bun (via the
wrapper chain — see `claude-code-wrapper` fragment). If the wrapper
got bypassed and claude ran under Node, the runtime uses fnv1a and
the salt produces a different buddy.

**State dir corruption**: the state dir contains a real binary
copy (not symlinks). If the binary gets corrupted or manually
truncated, `rm -rf $XDG_STATE_HOME/claude-code-buddy/` and re-run
`home-manager switch` — activation script rebuilds from scratch.

### Verifying activation worked

After `home-manager switch`:

1. `ls $XDG_STATE_HOME/claude-code-buddy/fingerprint` — exists
2. `file $XDG_STATE_HOME/claude-code-buddy/claude` — should show
   an executable binary, not a broken symlink
3. `grep -c friend-2026-401 $XDG_STATE_HOME/claude-code-buddy/claude`
   — should be 0 (old marker replaced with new salt)
4. `jq .companion ~/.claude.json` — should be `null` until next
   claude launch
5. Launch claude. `/buddy` should show the configured species.

### Not here

Wrapper chain and buddy binary resolution: see
`claude-code-wrapper` fragment in this same directory.

`ai.claude.buddy` fanout mechanics and the ai module's per-CLI
gating: see `ai-module-fanout` fragment under `modules/ai/`.
