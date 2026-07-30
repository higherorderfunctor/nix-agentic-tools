# Evidence: machine-state measurements (Kiro CLI v3)

Seven replayable records measured over one machine's own `~/.kiro` state and its
installed KAS bundles, rather than read out of code. All captured against KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29. Companion to
`records/concurrency-and-nesting.md`, which covers the same engine by code read;
where the two overlap, that file has the mechanism and this one has the
observation.

## How to replay these

Resolve the bundle first. Seven KAS versions were installed on the capture
machine, so the resolver refuses on ambiguity rather than guessing — R-machine-7
is entirely about why.

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
ver=$(kiro-cli --version | awk '{print $NF}')                 # 2.15.1
shopt -s nullglob
kasdirs=( "$HOME/.local/share/kiro-cli/kas/${ver}-"*/ )
[ "${#kasdirs[@]}" -eq 1 ] || { echo "AMBIGUOUS KAS - refuse (found ${#kasdirs[@]})"; exit 1; }
kas="${kasdirs[0]}"
bundle="${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
kasid=$(basename "${kas%/}")
```

At capture `$bundle` was **20752757** bytes and `$kasid` was the id above — both
as expected.

Five conventions that matter for replay:

- **Privacy.** Every command here reports event **types**, **counts**, and
  **field names**. None reads or prints transcript message content. Paths that
  would name a workspace are either abstracted (`<home>`, `<16hex>`, `<uuid>`)
  or reduced to a classification before printing. Keep it that way when
  re-running: a transcript is a conversation.
- **The root corpus is LIVE; the sub-execution corpus was static.** A v3 TUI
  session was running throughout capture, appending to its own transcript.
  Measured drift over about twenty-five minutes in the same shell: root
  `tool_call` rows read **11116**, then **11124**, then **11136**; total root
  rows **56105** then **56195**; hook rows **452** then **453**. Sub-execution
  counts did not move by a single row. Consequence for replay: **every root
  figure below is one snapshot, taken 2026-07-30T02:07Z**, and re-running will
  give **≥** these values. Read all of a record's numbers in one command; do not
  stitch two runs together, or the internal cross-checks stop closing.
- **Every count here ships its denominator**, because that is the only thing
  that turns a zero into evidence.
- **Tool versions matter more than usual.** Capture used `jq 1.8.2`, `bfs 4.1.1`
  as `find`, and **ugrep 7.5.0** as `grep`. `bfs` rejects
  `find -newermt '-10 minutes'` (it wants ISO-8601), and ugrep's `-c -o` counts
  occurrences where GNU `grep -c` counts lines.
- **`xargs -0 jq` batches, and that is deliberate.** `input_filename` still
  attributes each row correctly, and one `jq` per file is ~10x slower over 794
  files. Do **not** add `2>/dev/null` to these pipelines: nine root transcripts
  are zero-length, and silencing `jq` hides which files were skipped.

---

## R-machine-1 — Establish that hook invocations are absent from default-dispatch sub-executions, and bound exactly how far that zero reaches

**Establishes:** across **605** sub-execution transcripts there are **0**
hook-invocation events, while the same files carry **10871** tool-call events —
so the event family is recorded there and the zero is absence, not a recording
gap. Restricted to the only sessions where the comparison is meaningful — the
**14** that ran both a hook and at least one sub-execution — their **287**
sub-execution transcripts hold **0** hook events against **6104** tool-call
events.

**Why it matters:** it is the observational half of the `skipHooks` finding: the
default dispatch adapter suppresses prompt/stop hooks in children, so a design
that wanted hooks as the worker-to-root bus gets silence on the default path.
But the bound matters as much as the zero. Every hook live in those 14 sessions
fires on `Stop`, `SessionStart`, `Manual`, or `UserPromptSubmit` — exactly the
gated triggers. **This dataset says nothing about `PreToolUse`/`PostToolUse` in
sub-executions**, and reading it as if it did is the error the record exists to
prevent.

**Semantic anchor:** each persisted session directory holds a root transcript as
newline-delimited JSON, and — only if it ever dispatched — a sibling directory
of one transcript per sub-execution. Every row is `{id, timestamp, payload}` and
the event kind is a string on the payload. A hook firing appears as its own
event kind carrying the hook's identifier, its action type, and a completion
status; a tool invocation appears as a different kind, paired 1:1 with a result
kind. Count the hook kind and the tool kind in both corpora. The load-bearing
comparison is not root-versus-sub globally: it is the two corpora **within the
sessions that had both**, because a session with no hook installed cannot
demonstrate anything.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
cd "$HOME/.kiro/sessions"
roots() { find . -name messages.jsonl -type f -not -path './cli/*' -print0; }
subs()  { find . -path '*/sub-executions/*.jsonl' -type f -print0; }
rows()  { xargs -0 jq -r --arg t "$1" 'select(.payload.type==$t)|input_filename'; }

printf 'root transcripts           %4s\n' "$(roots | tr -dc '\0' | wc -c)"
printf 'sub-execution transcripts  %4s\n' "$(subs  | tr -dc '\0' | wc -c)"
for t in ContextualHookInvoked tool_call; do
  printf '%-22s root %6s rows / %3s files    sub %6s rows / %3s files\n' "$t" \
    "$(roots | rows "$t" | wc -l)" "$(roots | rows "$t" | sort -u | wc -l)" \
    "$(subs  | rows "$t" | wc -l)" "$(subs  | rows "$t" | sort -u | wc -l)"
done
```

**Output at capture:**

```
root transcripts            189
sub-execution transcripts   605
ContextualHookInvoked  root    453 rows /  53 files    sub      0 rows /   0 files
tool_call              root  11136 rows / 152 files    sub  10871 rows / 605 files
```

**Command** (the informative subset — the number the claim actually rests on):

```bash
cd "$HOME/.kiro/sessions"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
find . -name messages.jsonl -type f -not -path './cli/*' -print0 \
  | xargs -0 jq -r 'select(.payload.type=="ContextualHookInvoked")|input_filename' \
  | sort -u | while IFS= read -r f; do
      d=$(dirname "$f"); [ -d "$d/sub-executions" ] && printf '%s\n' "$d/sub-executions" || :
    done | sort -u > "$tmp"
printf 'sessions with hooks AND sub-executions : %s\n' "$(wc -l < "$tmp")"
printf 'their sub-execution transcripts        : %s\n' \
  "$(tr '\n' '\0' < "$tmp" | xargs -0 -I{} find {} -name '*.jsonl' -type f | wc -l)"
for t in ContextualHookInvoked tool_call; do
  printf '  %-22s %6s rows\n' "$t" \
    "$(tr '\n' '\0' < "$tmp" | xargs -0 -I{} find {} -name '*.jsonl' -type f -print0 \
        | xargs -0 jq -r --arg t "$t" 'select(.payload.type==$t)|1' | wc -l)"
done
echo "--- which hook documents were live in those sessions, and their triggers:"
jq -r '[.hooks[].trigger]|sort|join(",")' "$HOME/.kiro/hooks/kiro-memory.json"
```

**Output at capture:**

```
sessions with hooks AND sub-executions : 14
their sub-execution transcripts        : 287
  ContextualHookInvoked       0 rows
  tool_call                6104 rows
--- which hook documents were live in those sessions, and their triggers:
Manual,SessionStart,Stop,UserPromptSubmit
```

**Positive controls:** the claim is an absence, so it needs two independent
controls, and both are in the outputs above rather than in a separate command.

1. **The query works.** The identical `jq` expression, same corpus root, finds
   **453** hook rows in **53** root transcripts. A future re-run that reports 0
   in both corpora has lost its grip on the field name, not discovered a change.
2. **The files record events at all.** The same 605 sub-execution transcripts
   carry **10871** tool-call rows (**6104** in the informative 287). A file that
   records nothing cannot be evidence that hooks did not fire in it.

**Notes:** what makes the absence hold up is that the 14 sessions had hooks that
demonstrably fired — in the root of the very same session — while their children
recorded none. The scoping restriction is not pedantry: a **correction to a
commonly stated form of this finding.** It is often written as "the only hook
document ever present on this machine used exactly the three gated triggers".
That is **not reproducible** — `probe-pretooluse` and `probe-posttooluse`
invocations do exist in this corpus (one transcript each, see R-machine-2's
output). The reproducible statement is narrower and is the one above: no
tool-hook invocation ever occurred in a session that also ran sub-executions, so
the tool-hook question is untouched by this data and needs a live fixture. This
record goes stale if the hook event kind is renamed (the controls will say so),
if sub-execution transcripts stop being written per child, or once any session
runs a `PreToolUse`/`PostToolUse` hook _and_ dispatches — at which point re-run
it, because it would then bear on the ungated triggers too.

---

## R-machine-2 — Establish that hooks under the home directory do load, by finding home-rooted hook firings inside project sessions

**Establishes:** **419** of **453** hook invocations carry an identifier rooted
at the home directory's hook folder, and **all 419** occurred in sessions whose
workspace root is a project directory, **not** the home directory. Zero occurred
in a session rooted at `$HOME`. Three distinct home-rooted hook documents
account for them.

**Why it matters:** this is the measurement that **reversed an earlier
conclusion**. The recorded belief was that v3 loads hooks only from
`<workspaceRoot>/.kiro/hooks/`, which made global hook delivery look impossible
and would have ruled out shipping hooks from a user-level config manager. It is
false: the global root loads. The earlier conclusion had two independent
confounders producing one symptom — a symlinked hook file is skipped with no
warning, and `KIRO_HOME` hides the home hook root rather than relocating it — so
a probe "confirmed" the wrong inference twice.

**Semantic anchor:** a hook-invocation event names the hook by a **composite
identifier**: the absolute path of the hook JSON document, then `#hook-` and the
**zero-based index of that hook within the document's own array**. So the
identifier is a location, not a name, and its prefix tells you which load root
the document came from. Partition every hook firing by that prefix — home hook
folder versus a workspace's own — then, for the home-rooted ones, look up the
owning session's recorded workspace roots and ask whether that root is the home
directory. If it is not, the home root loaded into a project session.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (output is classified before printing, so it names no workspace):

```bash
cd "$HOME/.kiro/sessions"
find . -name messages.jsonl -type f -print0 \
  | xargs -0 jq -r --arg h "$HOME/.kiro/hooks/" \
      'select(.payload.type=="ContextualHookInvoked")
       | select(.payload.hookId|startswith($h))
       | [input_filename, (.payload.hookId|sub("^.*/";"")), .payload.hookActionType, .payload.status] | @tsv' \
  | while IFS=$'\t' read -r f idtail act st; do
      ws=$(jq -r '(.workspacePaths // [])[0] // "<none>"' "$(dirname "$f")/session.json")
      case "$ws" in
        "$HOME")  cls="workspace == \$HOME" ;;
        "<none>") cls="no workspace recorded" ;;
        *)        cls="workspace is a project dir (!= \$HOME)" ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "$cls" "$(printf '%s' "$idtail" | sed -E 's/^[^#]*\.json/<file>.json/')" "$act" "$st"
    done | sort | uniq -c | sort -rn
echo "--- distinct home-rooted hook FILES that fired:"
find . -name messages.jsonl -type f -print0 \
  | xargs -0 jq -r --arg h "$HOME/.kiro/hooks/" \
      'select(.payload.type=="ContextualHookInvoked")|select(.payload.hookId|startswith($h))|.payload.hookId' \
  | sed -E 's/#hook-[0-9]+$//' | sort -u | wc -l
```

**Output at capture:**

```
    213 workspace is a project dir (!= $HOME)	<file>.json#hook-3	runCommand	completed
    156 workspace is a project dir (!= $HOME)	<file>.json#hook-0	runCommand	completed
     48 workspace is a project dir (!= $HOME)	<file>.json#hook-1	runCommand	completed
      2 workspace is a project dir (!= $HOME)	<file>.json#hook-2	runCommand	completed
--- distinct home-rooted hook FILES that fired:
3
```

The four rows sum to **419**, and no row lands in either other bucket.

**Command** (the load-root partition and the ordinal's denominator):

```bash
cd "$HOME/.kiro/sessions"
find . -name messages.jsonl -type f -print0 \
  | xargs -0 jq -r 'select(.payload.type=="ContextualHookInvoked")
      | [.payload.hookId, .payload.name, .payload.hookActionType, .payload.status] | @tsv' \
  | sed -e "s|$HOME|<home>|g" \
  | awk -F'\t' '{ p=$1; gsub(/[^\/]*\.json/,"<file>.json",p); gsub(/#hook-[0-9]+/,"#hook-N",p); print p"\t"$4 }' \
  | sort | uniq -c | sort -rn
echo "--- the surviving home-rooted document: real file or symlink, and its array length"
find "$HOME/.kiro/hooks" -maxdepth 1 -name '*.json' -printf '%y %l %f\n'
jq -r '"hooks=\(.hooks|length)  triggers=\([.hooks[].trigger]|join(","))"' "$HOME/.kiro/hooks/kiro-memory.json"
```

**Output at capture:**

```
    419 <home>/.kiro/hooks/<file>.json#hook-N	completed
     16 <home>/Documents/projects/nix-agentic-tools/.kiro/hooks/<file>.json#hook-N	completed
      9 <home>/Documents/projects/nix-agentic-tools-ideation/.kiro/hooks/<file>.json#hook-N	completed
      5 /tmp/<redacted-scratch>/kiro-hooktest/.kiro/hooks/<file>.json#hook-N	completed
      3 /tmp/kiro-hitl-proj/.kiro/hooks/<file>.json#hook-N	completed
      1 /var/tmp/nat-kiro-probe/work/.kiro/hooks/<file>.json#hook-N	completed
```

**419 home-rooted + 34 workspace-rooted = 453**, the full hook population of
R-machine-1. Two load roots, and both are real: the home folder and each
workspace's own `.kiro/hooks/`.

```
f  kiro-memory.json
hooks=4  triggers=Stop,SessionStart,Manual,UserPromptSubmit
```

**Positive controls:** the primary claim is a **presence**, so it needs none.
The subordinate claim — "no home-rooted hook fired in a `$HOME`-rooted session"
— is an absence whose control is the other row of the same partition: the
classifier emitted `workspace is a project dir` 419 times, proving the `case`
arm and the workspace lookup both work. A run where every row came back
`no workspace recorded` would mean `session.json` moved, not that workspaces
changed.

**Notes:** the ordinal distribution reads against the document's array —
`#hook-3` is `UserPromptSubmit` and fired 213 times, `#hook-0` is `Stop` at 156,
`#hook-1` is `SessionStart` at 48, `#hook-2` is `Manual` at 2 — so the id's
index really is a position in `.hooks[]`, and a reordering of that array
silently re-points every historical id. Three home-rooted documents fired
historically but only one survives on disk; the other two were probes since
deleted, which is why `probe-*` names appear in the corpus with no file behind
them. That surviving document is a **regular file** (`f`, empty symlink target),
consistent with the invariant that a symlinked hook document is skipped without
a warning — so this record is not evidence that symlinks work, and must not be
read as such. The scratch path in the second output is redacted by hand because
it embeds a session-specific temp directory; nothing else in the output was
altered. This record goes stale if the id stops being `<path>#hook-<index>`, or
if the home hook root stops being consulted — in which case the 418 collapses
toward 0 while the workspace-rooted rows survive, which is a distinguishable
signature.

---

## R-machine-3 — Establish the on-disk layout of a v3 session and the single field that distinguishes a sub-execution row from a root row

**Establishes:** sessions are stored two levels deep — a 16-hex workspace
bucket, then one `sess_<uuid>` directory per session — with `session.json` in
all **212**, a root transcript in **189**, and a **flat** `sub-executions/`
directory in the **44** that ever dispatched. The discriminator is
**`payload.subExecutionId`**: present on **29791** of **29829** sub-execution
rows and on **0** of **56195** root rows. The 38 exceptions are exactly the
nested dispatch/complete rows, which carry `parentExecutionId` and
`subSessionId` instead.

**Why it matters:** it is the whole basis for reconstructing the real agent tree
after a run, which is the only honest cross-check on a scheduler — the TUI
collapses completed subagent nodes and counts only direct children, so a
grandchild reads as root-spawned. The layout also fixes what is **not** encoded:
`sub-executions/` is flat and the filename is a bare uuid, so **depth appears
nowhere in the path**. Depth must be derived from the parent/child edges in the
rows, matching the code-read finding that depth is an in-process constructor
field and never leaves the process.

**Semantic anchor:** under the CLI's state directory, `sessions/` holds one
opaque fixed-width hex bucket per workspace plus one legacy bucket named for the
v2 engine holding flat per-conversation files. Inside a v3 bucket, each session
is a directory named with a `sess_` prefix and a uuid, holding its metadata
object, its append-only transcript, optional publish cursors, an optional
snapshots directory, and — only when it dispatched — a directory of per-child
transcripts named by the child's own uuid, all siblings regardless of nesting
depth. In the transcript rows, a child's execution identity rides on a payload
field naming the sub-execution; root rows never carry it. Dispatch bookkeeping
is the exception that proves the rule: a dispatch event describes a
relationship, so it carries the parent's execution id and the child's session id
rather than a single sub-execution id.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
cd "$HOME/.kiro/sessions"
echo "=== top-level buckets"
ls -1 . | sed -E 's/^[0-9a-f]{16}$/<16-hex>/' | sort | uniq -c
echo "=== v3 session dir: entries present, per-session (v2 'cli' bucket excluded)"
find . -mindepth 2 -maxdepth 3 -not -path './cli/*' \
  | sed -E 's|^\./[0-9a-f]{16}/sess_[0-9a-f-]{36}|<16hex>/sess_<uuid>|; s|/sub-executions/[0-9a-f-]{36}\.jsonl$|/sub-executions/<uuid>.jsonl|' \
  | sort | uniq -c | sort -rn
echo "=== session.json top-level key union (denominator = every session.json)"
find . -name session.json -type f -not -path './cli/*' -print0 | xargs -0 jq -r 'keys[]' | sort | uniq -c | sort -rn
```

**Output at capture:**

```
=== top-level buckets
     19 <16-hex>
      1 cli
=== v3 session dir: entries present, per-session (v2 'cli' bucket excluded)
    212 <16hex>/sess_<uuid>/session.json
    212 <16hex>/sess_<uuid>
    189 <16hex>/sess_<uuid>/messages.jsonl
    120 <16hex>/sess_<uuid>/snapshots
     92 <16hex>/sess_<uuid>/publish.cursor
     44 <16hex>/sess_<uuid>/sub-executions
     22 <16hex>/sess_<uuid>/publish-sub.cursor
=== session.json top-level key union (denominator = every session.json)
    212 workspacePaths
    212 title
    212 semanticReviewEnabled
    212 schemaVersion
    212 lastModifiedAt
    212 id
    212 ftaEnabled
    212 dataModelVersion
    212 createdAt
    212 agentMode
    199 autopilot
    188 modelId
    187 specWorkflow
    187 specSkipClarificationEnabled
    187 specPlanEnabled
    180 status
    178 effortLevel
    103 description
     18 workflowsEnabled
     18 _meta
```

**Command** (the discriminator, and the event vocabulary of each corpus):

```bash
cd "$HOME/.kiro/sessions"
for role in root sub; do
  case $role in
    root) find . -name messages.jsonl -type f -not -path './cli/*' -print0;;
    sub)  find . -path '*/sub-executions/*.jsonl' -type f -print0;;
  esac | xargs -0 jq -r 'if (.payload|has("subExecutionId")) then "has-subExecutionId" else "absent" end' \
       | sort | uniq -c | awk -v r="$role" '{printf "  %-5s %-20s %7d\n", r, $2, $1}'
done
echo "=== key set of the 38 exceptions"
find . -path '*/sub-executions/*.jsonl' -type f -print0 \
  | xargs -0 jq -c 'select(.payload.type=="sub_agent_start")|.payload|keys' | sort -u
echo "=== event kinds per corpus"
for role in root sub; do
  echo "--- $role"
  case $role in
    root) find . -name messages.jsonl -type f -not -path './cli/*' -print0;;
    sub)  find . -path '*/sub-executions/*.jsonl' -type f -print0;;
  esac | xargs -0 jq -r '.payload.type' | sort | uniq -c | sort -rn
done
```

**Output at capture:**

```
  root  absent                 56195
  sub   absent                    38
  sub   has-subExecutionId     29791
=== key set of the 38 exceptions
["explanation","parentExecutionId","prompt","subAgentName","subSessionId","type"]
=== event kinds per corpus
--- root
  11136 tool_result
  11136 tool_call
  10951 assistant
   7776 session_metadata
   4528 pending_interaction
   4526 interaction_resolved
   1006 user
    807 turn_start
    805 turn_end
    801 usage_summary
    801 session_event
    587 sub_agent_start
    586 sub_agent_complete
    453 ContextualHookInvoked
    158 steering_inclusion
    130 session_start
      8 tombstone
--- sub
  10871 tool_result
  10871 tool_call
   7434 assistant
    615 steering_inclusion
     19 sub_agent_start
     19 sub_agent_complete
```

The kind counts sum to exactly **56195** and **29829**, matching the two
discriminator totals above — so no row was dropped or double-counted, and the
two commands saw the same corpus.

**Positive controls:** the "0 of 56105 root rows carry the field" half is an
absence, and its control is the adjacent row of the same partition: the same
expression found the field on 29791 sub-execution rows. If both buckets read
`absent`, the field was renamed.

**Command** (internal consistency — two independent paths to the same 44):

```bash
cd "$HOME/.kiro/sessions"
printf 'sub-executions dirs on disk:          %s\n' "$(find . -type d -name sub-executions | wc -l)"
printf 'root transcripts w/ sub_agent_start:  %s\n' \
  "$(find . -name messages.jsonl -type f -not -path './cli/*' -print0 \
     | xargs -0 jq -r 'select(.payload.type=="sub_agent_start")|input_filename' | sort -u | wc -l)"
```

**Output at capture:**

```
sub-executions dirs on disk:          44
root transcripts w/ sub_agent_start:  44
```

**Notes:** the root `tool_call` figure here agrees with R-machine-1's **because
both come from the one 02:07Z snapshot**; an earlier pair of runs had them at
11116 and 11124 respectively, which is exactly the stitching error the preamble
warns about. The sub-execution figures were identical in every run — a static
corpus beside a live one. Nine root transcripts are zero-length, which is why
`189` transcript files yield event counts from only `152`. The `tombstone` kind
is the compaction marker of R-machine-6's first issue, present **8** times here.
Note `session.json` carries `schemaVersion` `1.0.0` and `dataModelVersion` `1`
on **all 212** files even though the key set clearly changed — so **the schema
version cannot be used to detect field availability** (see R-machine-4). This
record goes stale if the bucket depth changes, if `sub-executions/` becomes
nested per depth (which would be an improvement worth noticing), or if the
discriminator field is renamed.

---

## R-machine-4 — Establish that the workflow-enable flag is persisted but has never been true here, and that it is invisible to the schema version

**Establishes:** of **212** persisted `session.json` files, **18** carry
`workflowsEnabled` and every one of them is **`false`**; **194** omit the key;
**zero** are `true`. The 18 that carry it are exactly the 18 that carry `_meta`
— perfect co-presence, 194 with neither. All 212 report `schemaVersion` `1.0.0`
and `dataModelVersion` `1`.

**Why it matters:** the native workflow surface (a repeat/parallel drain plus
mid-flight child-to-parent messaging) is registered all-or-nothing off this one
persisted boolean, resolved on session **load** and not on session **new**. So
the distribution is the empirical statement that the surface has never been
switched on here, and that turning it on means **seeding a session file and
resuming it** rather than flipping something at launch. The co-presence with
`_meta` dates the field: it arrived with a schema revision that did **not** bump
either version number, so a fixture must probe for the key and can never gate on
the version.

**Semantic anchor:** a persisted session's metadata **is** its top-level JSON
object — there is no nested `metadata` wrapper — so the enable flag is a
top-level boolean beside the title, workspace roots, model id, agent mode,
effort level, and the spec/review toggles. Bucket every session file three ways:
key present and true, present and false, absent. The absent bucket is historical
sessions written before the field existed, so it should be frozen while the
present buckets grow; if the absent bucket ever grows, the field stopped being
emitted.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
cd "$HOME/.kiro/sessions"
total=$(find . -name session.json -type f -not -path './cli/*' | wc -l)
echo "total session.json files: $total"
find . -name session.json -type f -not -path './cli/*' -print0 \
  | xargs -0 jq -r 'if has("workflowsEnabled") then (.workflowsEnabled|tostring) else "ABSENT" end' \
  | sort | uniq -c | awk -v T="$total" '{printf "  workflowsEnabled=%-8s %4d / %s\n",$2,$1,T}'
echo "--- do the buckets sum to the denominator?"
find . -name session.json -type f -not -path './cli/*' -print0 \
  | xargs -0 jq -r 'if has("workflowsEnabled") then (.workflowsEnabled|tostring) else "ABSENT" end' | wc -l
echo "--- co-presence with _meta, and the schema version"
find . -name session.json -type f -not -path './cli/*' -print0 | xargs -0 jq -r \
  '[(if has("workflowsEnabled") then "wfE" else "-" end),(if has("_meta") then "_meta" else "-" end)]|join("+")' \
  | sort | uniq -c
find . -name session.json -type f -not -path './cli/*' -print0 \
  | xargs -0 jq -r '[.schemaVersion,.dataModelVersion]|@tsv' | sort | uniq -c
```

**Output at capture:**

```
total session.json files: 212
  workflowsEnabled=ABSENT    194 / 212
  workflowsEnabled=false      18 / 212
--- do the buckets sum to the denominator?
212
--- co-presence with _meta, and the schema version
    194 -+-
     18 wfE+_meta
212 1.0.0	1
```

**Positive controls:** the load-bearing claim is that **no** session is `true`,
which is an absence. Two controls sit in the same output. The `false` bucket is
non-empty at 18, proving the key name is right and `jq` can read the value — a
misspelled key would report 212 `ABSENT`. And the buckets sum to exactly the
denominator, proving no file was skipped or double-counted.

**Notes:** an earlier measurement of the same three buckets on this machine read
**205 total: 11 false, 194 absent, 0 true**. This run reproduces the shape and
the conclusion while the `false` count grew 11 to 18 and `ABSENT` held at
exactly **194** — which is the predicted signature and is the strongest evidence
in this file that the absent bucket is historical rather than current behavior.
The enable path being load-time also implies the flag is fixed for a session's
lifetime, so a fixture needs one pre-seeded session per run rather than a
mid-session toggle; that part is a code-read claim, not measured here. This
record goes stale the moment any session reads `true` — at which point it stops
being evidence of a dead surface and starts being a baseline.

---

## R-machine-5 — Establish that nested sub-executions have really run here, that they reached depth 2 and never depth 3, and that the transcripts stay flat

**Establishes:** **19** dispatch events appear **inside** sub-execution
transcripts — i.e. a child dispatching its own child — issued by **7** distinct
parents and producing **19** distinct children. All 19 children have their own
transcript, and every one of those lands in the **same flat** `sub-executions/`
directory of the **root** session. **Zero** of the 19 children themselves
dispatched, so depth 2 is the deepest nesting this machine has executed.
Per-parent nested fan-out peaked at **4**.

**Why it matters:** nesting is not theoretical on this platform, and it is not
what a role-level "subagents cannot recurse" observation suggests — it has run,
repeatedly, under two different agent names. That is the observational
counterpart to the engine's depth ceiling of 5, and it is what makes a
dispatcher tier a real option. Two cautions come with it. The flat layout means
**the filesystem does not tell you the depth** — the tree exists only in the
parent/child edges, so any depth accounting has to reconstruct it. And the peak
fan-out of 4 is **under** the 5-permit ceiling, so **this corpus does not
exercise the per-execution semaphore at all**; the claim that a nested tier
multiplies capacity is untested by this data and remains a code read.

**Semantic anchor:** a dispatch event names the child's session and the agent
profile invoked. Find those events in the **child** transcripts rather than the
root transcript: one occurring there means a sub-execution dispatched, which is
nesting by definition. Then treat the child ids as nodes and ask whether any
node appears on both sides — as a dispatcher and as a dispatched child. That
intersection is the depth-3 population, and an empty intersection is the honest
statement of "depth 2 reached, depth 3 never". Locate each named child's own
transcript to establish whether the store nests by depth or keeps one flat
directory per root session.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
cd "$HOME/.kiro/sessions"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
find . -path '*/sub-executions/*.jsonl' -type f -print0 \
  | xargs -0 jq -r 'select(.payload.type=="sub_agent_start")
      | [ (input_filename|sub(".*/";"")|sub("\\.jsonl$";"")), .payload.subSessionId, .payload.subAgentName ] | @tsv' > "$tmp"
printf 'nested dispatches (sub_agent_start rows inside sub-execution transcripts) : %s\n' "$(wc -l < "$tmp")"
printf '  distinct L1 dispatchers                                                : %s\n' "$(cut -f1 "$tmp" | sort -u | wc -l)"
printf '  distinct L2 children                                                   : %s\n' "$(cut -f2 "$tmp" | sort -u | wc -l)"
printf '  L2 children that themselves dispatched (would be depth 3)              : %s\n' \
  "$(comm -12 <(cut -f1 "$tmp" | sort -u) <(cut -f2 "$tmp" | sort -u) | wc -l)"
echo '  agent names dispatched L1->L2:'
cut -f3 "$tmp" | sort | uniq -c | sed 's/^/    /'
echo '  children per dispatcher (ceiling is 5 permits per execution):'
cut -f1 "$tmp" | sort | uniq -c | awk '{print $1}' | sort -rn | uniq -c \
  | awk '{printf "    %d dispatcher(s) with %d child(ren)\n",$1,$2}'
echo '  where each L2 transcript lives:'
cut -f2 "$tmp" | while IFS= read -r id; do find . -name "$id.jsonl" -type f; done \
  | sed -E 's|^\./[0-9a-f]{16}/sess_[0-9a-f-]{36}|<16hex>/sess_<uuid>|; s|/[0-9a-f-]{36}\.jsonl$|/<uuid>.jsonl|' \
  | sort | uniq -c | sed 's/^/    /'
```

**Output at capture:**

```
nested dispatches (sub_agent_start rows inside sub-execution transcripts) : 19
  distinct L1 dispatchers                                                : 7
  distinct L2 children                                                   : 19
  L2 children that themselves dispatched (would be depth 3)              : 0
  agent names dispatched L1->L2:
          3 echo-leaf
         16 general-task-execution
  children per dispatcher (ceiling is 5 permits per execution):
    4 dispatcher(s) with 4 child(ren)
    3 dispatcher(s) with 1 child(ren)
  where each L2 transcript lives:
         19 <16hex>/sess_<uuid>/sub-executions/<uuid>.jsonl
```

**Positive controls:** the depth-3 claim is an absence, and its control is the
line above it: the identical set-intersection method, on the same two columns,
found **7** dispatchers and **19** children — so the columns parse and the
comparison is live. An empty intersection beside two non-empty sets is a real
zero; an empty intersection beside two empty sets means the dispatch event kind
was renamed. The "all 19 have a transcript" claim is a presence and the counted
19-of-19 is its own control: a missing child would show as a `0` bucket in the
final tally.

**Notes:** 19 dispatches to 19 distinct children is 1:1, so no child id was
reused and no dispatch was retried. The two agent names split 16/3, and the
three-way `1 child` group is the smaller probe. Dispatch-and-complete rows are
the 38 exceptions of R-machine-3 — they are the only sub-execution rows lacking
the sub-execution discriminator, which is exactly why this census reads them
from the child files and keys on `subSessionId`. This record goes stale if a
depth-3 run ever lands (the intersection becomes non-empty), if per-parent
fan-out reaches 5 (at which point the semaphore claim becomes testable from
disk), or if the store starts nesting child transcripts by depth.

---

## R-machine-6 — Establish the current upstream status of the seven issues this corpus depends on, and correct three that have moved

**Establishes:** statuses as of 2026-07-29, all in `kirodotdev/Kiro` unless
noted. Eight rows: the **seven** Kiro issues this corpus leans on — **6 open, 1
closed as a duplicate** — plus **one** companion report in a different repo,
open. Two of the eight open rows are **mischaracterised** by a previous reading,
and one of the corrections is the closure itself; all three are itemised below.

| #                                   | State                                     | One-line claim                                                                                                                                                                                |
| ----------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 10482                               | **open**, `compaction`/`cli`/`sub-agents` | A sub-agent crossing its compaction threshold writes a tombstone into the **parent** session declaring the parent's whole history truncated; patches attached, `pending-maintainer-response`. |
| 10394                               | **open**, `cli`                           | A sub-agent does **not** start the MCP servers its own profile declares; it sees only servers the parent already started, and its `disabledTools` is ignored.                                 |
| 8152                                | **open**, `cli`                           | MCP server processes are **orphaned at PPID=1** when a sub-agent session ends and never receive SIGTERM, so their own children survive too.                                                   |
| 10411                               | **closed** as duplicate of **8152**       | Accumulated stale sessions exhaust the thread pool and a new session panics with `WouldBlock`; closed by an automated duplicate detector, not by a fix.                                       |
| 10168                               | **open**, `cli`                           | A tool denied by the **parent's** permission rules falls through to `ask` instead of returning deny, so in `--no-interactive` the sub-agent stalls indefinitely and retries.                  |
| 6212                                | **open**, `cli`                           | A sub-agent invoking another sub-agent fails even in autopilot — but filed against **Kiro IDE 0.10.32**, not kiro-cli v3.                                                                     |
| 9566                                | **open**, `type:Feature`                  | Sub-agent sessions are unresumable: no session id is surfaced, so once a sub-agent ends its context is gone. Requests resume plus mid-flight steering.                                        |
| aws/amazon-q-developer-cli **3582** | **open**                                  | Companion report on the approval path — filed as a **documentation** bug: the docs imply a sub-agent can pause for approval, but the prompt cannot be answered.                               |

**Why it matters:** three of these bound the design space directly. 10482 is why
long-lived workers are unsafe at any efficiency — a worker that accumulates
enough context to compact corrupts its parent's stored history — so workers must
be short and recycled by construction. 10394 versus the vendor docs is why
worker profiles cannot be assumed to carry their own MCP servers, which decides
whether lean workers are achievable. 10168 plus 3582 are why a long-running
worker must never reach an approval prompt.

**Semantic anchor:** these are the seven upstream reports that the mechanics in
this corpus lean on: compaction crossing the parent boundary; MCP servers not
starting per sub-agent; MCP processes orphaning; stale sessions exhausting
resources; a denied tool stalling instead of denying under headless; nesting
reported as broken; and sub-agent sessions being unresumable. Re-check by
**searching the tracker for the behavior**, not by trusting these numbers — an
issue can be closed as a duplicate, retitled, or superseded, and **three** of
the eight rows above are already not what a previous reading recorded.

**Verified against:** GitHub, queried 2026-07-29 via the GitHub MCP server
(`issue_read` with `method: get`, plus `get_comments` for 10411 and
`search_issues` to find 9566 rather than guess a number).

**Command:**

```
GitHub MCP server, one call per row:
  issue_read   { method: "get", owner: "kirodotdev", repo: "Kiro", issue_number: N }
    for N in 10482, 10394, 8152, 10411, 10168, 6212, 9566
  issue_read   { method: "get", owner: "aws", repo: "amazon-q-developer-cli", issue_number: 3582 }
  issue_read   { method: "get_comments", owner: "kirodotdev", repo: "Kiro", issue_number: 10411 }
  search_issues { query: "repo:kirodotdev/Kiro subagent session resume" }
```

Equivalent, if the MCP server is unavailable:

```bash
for n in 10482 10394 8152 10411 10168 6212 9566; do
  gh api "repos/kirodotdev/Kiro/issues/$n" \
    --jq '[.number,.state,(.state_reason//"-"),([.labels[].name]|join("/")),.title]|@tsv'
done
gh api repos/aws/amazon-q-developer-cli/issues/3582 --jq '[.number,.state,.title]|@tsv'
```

**Output at capture** (fields transcribed from the MCP responses; titles
trimmed):

```
10482	open	-	pending-maintainer-response/compaction/cli/sub-agents	sub-agent compaction truncates the parent session (+ patches)
10394	open	-	pending-maintainer-response/cli	Subagent MCP servers not started independently
 8152	open	-	pending-maintainer-response/cli	MCP server processes are orphaned when subagent sessions end
10411	closed	completed	duplicate	kiro-cli crashes with thread pool resource exhaustion when stale sessions accumulate
10168	open	-	pending-maintainer-response/cli	Subagent commands stall on ask effect in headless mode
 6212	open	-	cli	Invoke a sub-agent from within the execution of another agent
 9566	open	-	type:Feature	Subagent Steering and History with session id
 3582	open	-	-	Subagents documentation bug suggests agents can pause for tool permission approval
```

10411's closure, verbatim from its comments:

```
🤖 Potential Duplicate Detected
This issue appears to be similar to:
- #8152: MCP server processes are orphaned when subagent sessions end (82% similar)
...
This issue has been automatically closed as it appears to be a duplicate of #8152.
```

**Positive controls:** not required — every row asserts a presence. The one
thing worth guarding is the **number**, and the guard is procedural: 9566 was
located by search, not recalled, because a wrong number returns a real issue
about something else and reads as a successful lookup.

**Three corrections this record makes.** Each was previously recorded otherwise,
and each is the kind of drift a record is for.

1. **10411 is CLOSED, not open** — and closed by an automated duplicate detector
   at 82% similarity, folded into 8152. The underlying defect is therefore
   **unfixed while its report is gone**, which is the worst of both states: do
   not read "closed" here as "resolved", and expect the symptom to persist.
2. **6212 is not a kiro-cli v3 report.** It is filed against Kiro IDE 0.10.32 in
   autopilot mode. It is entirely consistent with the reconciliation that the
   _default_ role lacks a dispatch tool, but citing it as evidence about the v3
   CLI engine overstates it.
3. **3582 does not report an indefinite hang.** Its title and framing are a
   **documentation** bug — the docs imply a sub-agent can pause for approval —
   and its Actual Behavior is that the approval prompt is displayed but cannot
   be answered, on `q` 1.23.1. The stall claim belongs to 10168; 3582
   corroborates the unanswerable-prompt shape, not the timeout.

**Notes:** 10482 carries patch scripts and a `--restore`, and its own census
method (pair a summary row's execution id against a dispatch event's child
session id in the same file) is directly runnable against the layout in
R-machine-3 — this machine shows **8** `tombstone` rows. Three of the open rows
sit on `pending-maintainer-response`, so re-check before relying on any of them.
This record goes stale on any state transition, and by design: it is a snapshot
whose whole value is the date on it.

---

## R-machine-7 — Establish that seven KAS bundles are installed, that only a version-pinned resolver finds the live one, and that a stale bundle can still be executing

**Establishes:** **7** KAS directories are installed; the CLI reports **2.15.1**
and resolves the single `2.15.1-*` directory. A naive lexical-first glob picks
**2.12.1** — **six** releases behind, positions 1 and 7 of 7. Lexical-last and
newest-by-mtime both happen to be **correct today**, which is what makes them
dangerous. And a **2.13.0** KAS server process was still running, reparented to
the user's init, after **551322** seconds (~6.4 days).

**Why it matters:** every record in this corpus is only as good as its bundle
resolution, and a wrong bundle produces plausible-looking output rather than an
error — a several-release-old bundle still contains most of the same strings, so
a mis-resolved grep silently confirms stale semantics. Two of the three obvious
resolvers coincide with the right answer on this machine right now and will stop
coinciding without any signal. The still-running 2.13.0 server is the second
lesson: an old KAS directory is not merely disk residue, so **do not clean up by
deleting all but the newest**, and expect a mis-resolved bundle to sometimes
match what an actually-running process is doing.

**Semantic anchor:** the CLI unpacks each agent-server release into its own
directory under its user data area, named `<semver>-<content hash>`, and keeps
every release it has ever unpacked. The live bundle is the one whose semver
equals what the CLI binary reports — nothing in the directory layout marks it,
there is no `current` symlink, and neither lexical nor mtime order is a
contract. So the only correct resolver reads the version from the binary, globs
for exactly that prefix, and **refuses on anything other than one match** rather
than taking a head. The bundle itself is then a fixed relative path beneath that
directory, inside the agent package's server output.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
base="$HOME/.local/share/kiro-cli/kas"
echo "installed:            $(ls -1d "$base"/*/ | wc -l) KAS directories"
echo "CLI reports:          $(kiro-cli --version)"
echo "naive lexical first:  $(basename "$(ls -1d "$base"/*/ | head -1)")"
echo "naive lexical last:   $(basename "$(ls -1d "$base"/*/ | tail -1)")"
echo "newest by mtime:      $(basename "$(ls -1dt "$base"/*/ | head -1)")"
echo "version-pinned:       $(basename "$(ls -1d "$base/$(kiro-cli --version | awk '{print $NF}')-"*/)")"
echo "--- release ordering"
ls -1d "$base"/*/ | sed -E 's|.*/kas/||; s|-.*||' | sort -V | nl -ba
```

**Output at capture:**

```
installed:            7 KAS directories
CLI reports:          kiro-cli 2.15.1
naive lexical first:  2.12.1-42744f1c8318bc8bb539697fb1f0be3f358b0428dce4993c22cb240b6d966511
naive lexical last:   2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc
newest by mtime:      2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc
version-pinned:       2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc
--- release ordering
     1	2.12.1
     2	2.12.3
     3	2.13.0
     4	2.13.1
     5	2.14.1
     6	2.14.2
     7	2.15.1
```

**Command** (why lexical-last and mtime are luck, not logic):

```bash
printf '%s\n' 2.9.0 2.15.1 2.14.2 2.10.0 | sort    | tr '\n' ' '; echo '   <- lexical sort'
printf '%s\n' 2.9.0 2.15.1 2.14.2 2.10.0 | sort -V | tr '\n' ' '; echo '   <- version sort'
stat -c '%y  %n' "$HOME/.local/share/kiro-cli/kas"/*/ \
  | sed -E 's|(/kas/[^-]*)-[0-9a-f]*/|\1-<hash>/|' | cut -c1-19,60- | sort
```

**Output at capture:**

```
2.10.0 2.14.2 2.15.1 2.9.0    <- lexical sort
2.9.0 2.10.0 2.14.2 2.15.1    <- version sort
2026-07-13 12:32:25are/kiro-cli/kas/2.12.1-<hash>/
2026-07-16 08:57:58are/kiro-cli/kas/2.12.3-<hash>/
2026-07-17 20:39:06are/kiro-cli/kas/2.13.0-<hash>/
2026-07-23 12:27:57are/kiro-cli/kas/2.13.1-<hash>/
2026-07-24 12:49:26are/kiro-cli/kas/2.14.1-<hash>/
2026-07-27 14:19:59are/kiro-cli/kas/2.14.2-<hash>/
2026-07-28 21:27:53are/kiro-cli/kas/2.15.1-<hash>/
```

A single-digit minor is enough to break lexical-last: `2.9.0` sorts **after**
`2.15.1`. mtime order is monotonic today only because releases were unpacked in
release order and never re-touched; a re-unpack, a restore, or a `touch`
reorders it, and mtime never knew which version the binary is.

**Command** (the stale executing bundle):

```bash
ps -eo pid=,ppid=,etimes=,args= | { grep -E 'kiro-cli|@kiro/agent' || true; } \
  | { grep -v ' grep ' || true; } \
  | awk '{
      kind="other";
      if ($0 ~ /acp-server\.js/)        kind="kas acp-server (node)";
      else if ($0 ~ /kiro-cli-chat/)    kind="kiro-cli-chat (rust)";
      else if ($0 ~ /kiro-cli-wrapped/) kind="kiro-cli launcher (rust)";
      ver="-";
      if (match($0,/kas\/[0-9]+\.[0-9]+\.[0-9]+/)) ver=substr($0,RSTART+4,RSTART+RLENGTH-RSTART-4);
      else if (match($0,/-kiro-cli-[0-9]+\.[0-9]+\.[0-9]+/)) ver=substr($0,RSTART+10,RSTART+RLENGTH-RSTART-10);
      printf "%-26s ver=%-7s pid=%-8s ppid=%-6s age=%ss\n", kind, ver, $1, $2, $3;
    }' | sort
ps -o pid=,args= -p 562561 | cut -c1-60
```

**Output at capture** (arguments elided by the `awk`; the launcher's real
command line is ~12 KB of `--trust-tools` entries):

```
kas acp-server (node)      ver=2.13.0  pid=3971258  ppid=562561 age=551322s
kas acp-server (node)      ver=2.15.1  pid=1240197  ppid=1240168 age=3281s
kas acp-server (node)      ver=2.15.1  pid=1317196  ppid=1317175 age=815s
kiro-cli-chat (rust)       ver=2.15.1  pid=1240123  ppid=1240114 age=3281s
kiro-cli-chat (rust)       ver=2.15.1  pid=1317135  ppid=1317127 age=816s
kiro-cli launcher (rust)   ver=2.15.1  pid=1240114  ppid=1239564 age=3281s
kiro-cli launcher (rust)   ver=2.15.1  pid=1317127  ppid=1240776 age=816s
other                      ver=-       pid=1240168  ppid=1240123 age=3281s
other                      ver=-       pid=1317175  ppid=1317135 age=816s
```

```
 562561 /usr/lib/systemd/systemd --user
```

**Positive controls:** the negative claim is "no naive resolver is reliable",
and its control is that all four resolvers **returned a real directory** rather
than failing — including the version-pinned one, which returned the expected id.
A re-run where every line is empty means the data directory moved, not that the
footgun was fixed.

**Notes:** two figures here **fail to reproduce** what was expected of them. The
count is **7**, not eight; and the lexical-first pick is **six** releases
behind, not three — the footgun is worse than recorded, and either restatement
would have picked a stale bundle silently. Bundle size (**20752757**) and the
`kasid` did match. The 2.13.0 server's parent is `systemd --user`, which is the
modern Linux form of the PPID=1 orphaning in R-machine-6's issue 8152; unlike
that report this one is the agent server itself rather than an MCP child, and it
survived three CLI upgrades. Note also that the transient shell running these
very commands can appear in a `ps` census, so classify by argument shape and
expect one extra short-lived row. This record goes stale on any KAS install or
prune, and the resolver's refuse-on-ambiguity behavior is the part worth
preserving even if every number here changes.
