---
name: kimchi-surface-scan
description: >-
  Use when you need to re-derive, verify or update the Kimchi CLI's server-side
  HTTP surface — which hosts it talks to, which endpoints, how each target is
  repointed, and what breaks when one is unreachable. Covers finding every
  released source tree in the store, identifying it by NAR hash, reading the
  compiled bun binary when no tree exists, and attributing a path to Kimchi
  rather than to a vendored SDK. Also regenerates the reference doc's diagrams.
disable-model-invocation: false
---

Re-run the extraction that produced `dev/references/kimchi-server-surface.md`.

## Cost, so you size this correctly

The original discovery burned 23 agents and roughly 4.4M tokens, and nearly all
of it went on not knowing the six things below. A rescan that starts from them
is a single pass over one source tree. Do not fan out. Read source, cite source,
and use a second agent only to check attribution on the handful of paths that a
vendored SDK could also own.

## Output

| Artifact                                  | What it is                              |
| ----------------------------------------- | --------------------------------------- |
| `dev/references/kimchi-server-surface.md` | The census. Authoritative; edit this.   |
| `dev/references/kimchi-capabilities.svg`  | Rendered from it. Never edited by hand. |
| `dev/references/kimchi-endpoints.svg`     | Rendered from it. Never edited by hand. |

## 1. Find every version's source tree, then identify it by hash

Kimchi is packaged from a release tarball, so `nix build` yields a compiled bun
binary and no source. Source trees from the `build/kimchi-from-source` line of
work are realized in the store, so find those instead.

```bash
for p in /nix/store/*-source; do
  [ -f "$p/package.json" ] && grep -q '@kimchi-dev/cli' "$p/package.json" \
    && echo "$p  $(nix hash path --type sha256 --sri "$p")"
done

git for-each-ref --format='%(refname:short)' refs/heads refs/remotes | while read -r br; do
  git show "$br:packages/kimchi/sources.json" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["version"], d["src"]["hash"])'
done | sort -u
```

**Never trust a `.drv` label, a directory name, or which branch pinned a tree.**
Two misidentifications happened during discovery and both looked authoritative:
one agent read a `.drv` whose commit message named a version and reported that
version; the orchestrator inferred a tree's version from the PR branch that
pinned it. Both were wrong. Only `nix hash path` against `sources.json` settled
it.

At the time of writing the method found 1.1.21, 1.1.25, 1.1.26, 1.1.27, 1.1.29
and 1.1.30, plus 1.1.22 through 1.1.24 for bisecting. **That list is a snapshot
of what the method returned once, not a lookup table** — re-run the loop rather
than assuming it.

## 2. With no source tree, read the binary

A bun single-file executable embeds its JS bundle as plaintext with identifiers
intact.

```bash
strings -n 6 /nix/store/<hash>-kimchi-<ver>/bin/kimchi > bundle.txt
```

Lines are enormous. Re-wrap on `;{}` boundaries at about 600 characters before
grepping, or every match returns the same line. Use the bundle only to confirm
that something is present or absent in a version with no tree. A source citation
beats a bundle offset every time, and the reference marks bundle-only citations
`B30:L…` for exactly that reason.

## 3. Attribution is the job. Finding paths is not

A grep for URL-shaped strings returns roughly the right _count_ and badly the
wrong _set_. The bundle vendors the OpenAI SDK, the Anthropic SDK, Google auth,
AWS STS, Cloudflare, xAI, GitHub, and the upstream
`@earendil-works/pi-coding-agent` harness (host `pi.dev`).

- `/v1/messages`, `/v1/models`, `/v1/files`, `/v1/batches` and
  `/v1/organizations/*` are byte-identical whether a vendored SDK owns them or
  Kimchi does.
- Around 150 such literals have zero call sites and are unreachable.
- But Kimchi **does** rebind both SDK base URLs through pi's provider config, so
  the two entry points it actually calls — `chat.completions.create` and
  `beta.messages.create` — really do land on `llm.kimchi.dev`.

**A finding counts only when you show which base URL the path is joined to at
the call site.** Trace the variable to its construction and to its default, and
report that chain in the cell. A path with no reachable call site belongs in the
"never called" tables, not in the capability matrix.

## 4. Run source first, binary second

Discovery ran the binary first and the source second, and the source pass
corrected the binary pass in several places. Source is cheaper, gives real file
paths, and its `*.test.ts` fixtures pin wire shapes that the bundle only hints
at. Confirm against the binary only for a version that has no tree.

## 5. Known base URLs — re-derive, do not assume

They are recorded so a rescan can see what moved.

```text
llm.kimchi.dev                 inference gateway + control plane
                               (models/metadata, route, search, credits, budget)
llm.kimchi.dev/openai/v1       OpenAI wire; vendored OpenAI SDK rebound here
llm.kimchi.dev/anthropic       Anthropic wire; vendored Anthropic SDK rebound here
app.kimchi.dev/api             sandbox control plane AND account identity
<workspace>.remote.kimchi.dev  per-workspace worker; host is server-assigned
api.cast.ai                    telemetry ingest, /stats analytics, key validation
```

`api.kimchi.dev` does not appear in any tree or in the binary. The documentation
page that names it is stale.

## 6. What an endpoint diff will not show you

The endpoint surface was frozen across 1.1.21 to 1.1.30: nothing was added,
removed or rehosted. What changed is **when** calls fire. A rescan that diffs
endpoint lists alone will report "no change" and miss everything that matters.
Check at least:

- **`KIMCHI_REMOTE_RUN` polarity.** It inverted from opt-in to opt-out in
  1.1.22. Read the variable's default, not its name.
- **Account gates on features.** A capability can become unreachable for an
  account class without any endpoint changing.
- **The global `fetch` patch's match rule.** Widening it re-routes calls the
  endpoint table still lists under their old host.
- **Default-on telemetry.** Check whether a call fires unasked, not only whether
  its endpoint exists.

Write these into the reference's "what did change" table with the version each
landed in. That table, not the matrix, is what a reader needs on a bump.

## 7. Regenerate the diagrams

`scripts/surface-tables.py` reads the reference's GFM tables, so a table and its
image cannot drift. It is stdlib-only Python; run it from the repo root after
every edit to the markdown.

```bash
scripts=dev/skills/kimchi-surface-scan/scripts

python3 "$scripts/surface-tables.py" svg dev/references/kimchi-server-surface.md \
  dev/references/kimchi-capabilities.svg \
  --title 'Kimchi CLI — server-side capabilities' --subtitle 'kimchi 1.1.30' \
  --cols 0,1,2 --widths 46,90,80

python3 "$scripts/surface-tables.py" svg dev/references/kimchi-server-surface.md \
  dev/references/kimchi-endpoints.svg \
  --title 'Kimchi CLI — endpoints and repointing' --subtitle 'kimchi 1.1.30' \
  --cols 0,3,4,5 --widths 40,82,30,63
```

Bump `--subtitle` to the version you scanned. The committed pair renders at
1834x3418 and 1849x4278; an unchanged reference must reproduce those exactly.

To read a projection in a terminal instead, or to check one capability without
opening the whole sheet:

```bash
python3 "$scripts/surface-tables.py" preview dev/references/kimchi-server-surface.md \
  --width 150 --cols 0,3,4 --filter search
```

The renderer keeps the table shape that recurs — the six-column capability
matrix — and drops the one-off tables around it, so new sections need no
registration. The `--widths` numbers come from each column's length distribution
rather than its maximum, which is why they are not round; the script's own
comment explains the arithmetic.

## Local validation

- `treefmt <file>` on everything you touch. Markdown is prettier with
  `proseWrap = "always"`.
- New vocabulary goes in `config/cspell/project-terms.txt`, sorted, and only if
  it is a real term.
- `devenv tasks run devenv:git-hooks:run` for the all-files diagnostic.

## If a second CLI ever needs this

Three steps carry over unchanged: hashing store paths to identify a version,
reading a bun bundle with `strings` when no tree exists, and refusing a finding
that cannot name the base URL its path is joined to at the call site. The
renderer is already generic — it takes any markdown with a repeated GFM table
and needs no Kimchi knowledge. What does not carry over is everything in
sections 5 and 6, which is a census of one product's hosts and one product's
behavior changes. One sample is not a pattern, so none of this has been
generalized; extract a shared skill when a second CLI actually needs it, not
before.
