---
name: index-repo-docs
description: >-
  Use when you need to create or update a reference doc from a repo's wiki,
  docs, and issues. Fetches and distills into a focused reference.
argument-hint: "<name-or-url|all> (e.g. git-branchless, git-absorb, all)"
disable-model-invocation: false
---

Fetch documentation from a repository and distill it into a practical reference
doc with concrete recipes and patterns. The output goes to `references/` in the
repo root.

## Known Repos

Use this lookup table to resolve short names to repos. If `$ARGUMENTS` doesn't
match a known name, treat it as a GitHub URL or `owner/repo`.

| Name             | Repo                     | Focus                                 |
| ---------------- | ------------------------ | ------------------------------------- |
| `git-branchless` | `arxanas/git-branchless` | Wiki, README, key issues on workflows |
| `git-absorb`     | `tummychow/git-absorb`   | README, man page, usage patterns      |
| `git-revise`     | `mystor/git-revise`      | README, docs, interactive usage       |

If `$ARGUMENTS` is `all` or empty (no arguments), iterate through every entry
in the table above and run the full indexing process for each one, skipping
repos that are up to date.

## Output

Write to: `references/<name>.md` in the repo root.

`<name>` is the short name from the lookup table or the repo name from the URL.

## Incremental Updates

The generated reference doc includes frontmatter with per-source indexing
metadata. Each source tracks its own date so partial re-indexing is possible
and so it's clear which sources have actually been fetched:

```yaml
---
repo: owner/repo
repo-head: <commit-sha>
repo-indexed: 2026-03-21
wiki-head: <commit-sha or null>
wiki-indexed: 2026-03-21
issues-indexed: 2026-03-21      # null if never fetched
discussions-indexed: 2026-03-21  # null if repo has no Discussions or never fetched
labels-indexed: 2026-03-21
label-head: <sha256 of sorted label name list>
doc-sources:                     # discovered doc files and external links
  - path: "Documentation/git-absorb.adoc"
    type: repo-file
    relevance: "man page with authoritative flag/option reference"
  - path: "docs/ARCHITECTURE.md"
    type: repo-file
    relevance: "internal design docs for understanding behavior"
  - url: "https://git-branchless.readthedocs.io/"
    type: external
    relevance: "official hosted documentation site"
    reachable: true
exclude-issue-patterns:
  - "renovate"
  - "dependabot"
  - "bump version"
value-labels:
  - name: "answered"
    reason: "confirmed solutions from maintainers"
  - name: "has workaround"
    reason: "practical alternatives users can follow"
---
```

A `null` date means that source has never been properly indexed — treat it
as needing a full fetch regardless of other source states.

On re-run:

1. **Read the existing reference doc** (if it exists) and parse its frontmatter
2. **Check remote HEADs** for both the repo and wiki:
   ```bash
   repo_head=$(gh api "repos/${owner}/${repo}/commits?per_page=1" --jq '.[0].sha')
   wiki_head=$(git ls-remote "https://github.com/${owner}/${repo}.wiki.git" HEAD 2>/dev/null | cut -f1 || echo "")
   ```
3. **Re-assess labels** (every run — see Label Discovery below). Compare the
   computed `label-head` against frontmatter to detect label changes.
4. **Compare each source independently:**
   - `repo-head` changed → re-fetch README/docs, re-discover doc tree, full regeneration
   - `wiki-head` changed → re-fetch wiki, full regeneration
   - `issues-indexed` is null or new issues exist since that date → fetch issues
   - `discussions-indexed` is null or new discussions since that date → fetch discussions
   - `label-head` changed → re-assess labels, may trigger issue re-fetch
   - `doc-sources` entries with `reachable: false` → re-check, prune if stale 3+ runs
   - `doc-sources` external URLs → spot-check reachability on full regeneration
5. **Check for new issues** updated since `issues-indexed`:
   ```bash
   gh api "search/issues?q=repo:${owner}/${repo}+type:issue+updated:>=${issues_indexed}T00:00:00Z&per_page=1" \
     --jq '.total_count'
   ```
6. **Check for new discussions** (if enabled) since `discussions-indexed`
7. If ALL sources are up to date, report "already up to date" and skip
8. Otherwise, fetch only the stale sources and **merge** insights into the
   existing doc. Only do a **full regeneration** if `repo-head` or `wiki-head`
   changed (the prose/structure source material changed). When only
   `issues-indexed` or `discussions-indexed` is stale, the existing doc text
   is the baseline — add new gotchas, recipes, and anti-patterns from issues
   without rewriting or condensing existing sections. Never drop existing
   content to make room; the 500-line limit applies to the final result, so
   if the doc is already near the limit, integrate only the highest-value
   issue insights.

### Exclude Patterns

The `exclude-issue-patterns` list in frontmatter filters out noise from
issues/discussions. On the first run, initialize it with common bot patterns:
`renovate`, `dependabot`, `bump version`, `release v`.

During indexing, if an issue title matches any pattern (case-insensitive),
skip it. If you encounter a new category of noise issues during distillation,
add the pattern to `exclude-issue-patterns` for future runs.

### Label Discovery

Every repo has different labels. Instead of hardcoding which labels matter,
discover and assess them dynamically.

**Fetch all labels** (runs every time, even on incremental updates):

```bash
gh api "repos/${owner}/${repo}/labels" --paginate \
  --jq '.[] | "\(.name)\t\(.description // "")\t\(.color)"'
```

**Compute `label-head`** — a hash of sorted label names to detect changes:

```bash
label_head=$(gh api "repos/${owner}/${repo}/labels" --paginate \
  --jq '[.[].name] | sort | join("\n")' | sha256sum | cut -d' ' -f1)
```

**Assess which labels have value** by classifying each into one of:

- **High value** — labels indicating resolved questions, workarounds, recipes,
  or confirmed patterns (e.g., "answered", "has workaround", "good first issue",
  "question", "howto", "cookbook", "workflow", "solved")
- **Medium value** — labels indicating feature discussions or design decisions
  that reveal capabilities (e.g., "enhancement", "feature request", "rfc",
  "design", "discussion")
- **Noise** — labels for project management, CI, or bot-generated content
  (e.g., "dependencies", "stale", "wontfix", "duplicate", "invalid")

Do NOT hardcode label names. Read the actual label names and descriptions,
then use judgment to classify them. Every repo is different — `git-branchless`
has "has workaround" and "answered", another repo might have "solved" or
"recipe".

**Cache the assessment** in the `value-labels` frontmatter field. Each entry
records the label name and a short reason why it's valuable. On subsequent
runs, if `label-head` hasn't changed, reuse the cached assessment. If labels
changed, re-assess and update the cache.

## Steps

1. **Resolve the repo** from `$ARGUMENTS` using the lookup table above, or
   parse as `owner/repo` or full URL.

2. **Check for incremental update** as described above. If up to date, skip.

3. **Fetch the wiki** (if it exists):
   ```bash
   tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-repo-index.XXXXXX")
   git clone --depth 1 "https://github.com/${owner}/${repo}.wiki.git" "$tmp_dir/wiki" 2>/dev/null || true
   ```

4. **Discover and fetch documentation**:

   Documentation lives in different places across repos. Use a multi-pass
   discovery approach and track what was found in `doc-sources` frontmatter.

   #### 4a. Fetch README (always)
   ```bash
   gh api "repos/${owner}/${repo}/readme" --jq '.content | @base64d' > "$tmp_dir/README.md"
   ```

   #### 4b. Scan repo tree for doc-like files
   Fetch the repo tree and filter for documentation files. Don't hardcode
   directory names — search broadly:
   First, get the default branch:
   ```bash
   default_branch=$(gh api "repos/${owner}/${repo}" --jq '.default_branch')
   ```

   ```bash
   gh api "repos/${owner}/${repo}/git/trees/${default_branch}?recursive=1" \
     --jq '.tree[] | select(.type=="blob") | .path' \
     | grep -iE '\.(md|adoc|rst|txt)$' \
     | grep -iE '^(docs?/|documentation/|man/|guide|readme|contributing|changelog|faq|usage|tutorial)' \
     > "$tmp_dir/doc-paths.txt"
   ```
   Also catch top-level doc files that aren't README:
   ```bash
   gh api "repos/${owner}/${repo}/git/trees/${default_branch}?recursive=1" \
     --jq '.tree[] | select(.type=="blob") | .path' \
     | grep -iE '^[^/]*\.(adoc|rst)$' \
     >> "$tmp_dir/doc-paths.txt"
   ```
   Fetch each discovered file:
   ```bash
   while read -r doc_path; do
     encoded=$(printf '%s' "$doc_path" | jq -sRr @uri)
     gh api "repos/${owner}/${repo}/contents/${encoded}" --jq '.content | @base64d' \
       > "$tmp_dir/repo-$(echo "$doc_path" | tr '/' '-')" 2>/dev/null || true
   done < "$tmp_dir/doc-paths.txt"
   ```

   #### 4c. Follow external documentation links
   Scan the README and any fetched docs for links to external documentation
   sites (readthedocs, GitHub Pages, gitbook, wiki URLs, etc.):
   ```bash
   grep -ohE 'https?://[^ )">]+' "$tmp_dir"/*.md "$tmp_dir"/*.adoc 2>/dev/null \
     | grep -iE '(readthedocs|gitbook|github\.io|wiki|docs\.)' \
     | sort -u > "$tmp_dir/external-links.txt"
   ```
   For each external link, fetch the page content if it's reachable and
   appears to be documentation (HTML or markdown). Use `WebFetch` for
   HTML pages. Record each in `doc-sources` with `type: external`.

   #### 4d. Reconcile with previous doc-sources
   If the existing frontmatter has `doc-sources`, compare:
   - **New paths not in previous run** → fetch and flag as new discovery
   - **Previous paths missing from tree** → mark `reachable: false`, keep
     the entry but note it's gone (the content may still be relevant if
     the file was moved or renamed)
   - **Previous external URLs** → re-check reachability, update status
   - **Prune** entries marked `reachable: false` for 3+ consecutive runs

   The `doc-sources` list persists across runs as the "memory" of what
   documentation exists for this repo. Each entry includes a `relevance`
   note explaining why it matters — this helps future runs prioritize.

5. **Discover and fetch issues/discussions** using multiple search signals.

   The goal is a thorough sample of usage-relevant content — not just the top
   10. Fetch greedily, deduplicate, and only prompt the user if volume is
   unmanageable.

   #### 5a. Count total issues to determine strategy

   Use the search API to get accurate issue counts (the REST issues endpoint
   and `open_issues_count` both include pull requests):
   ```bash
   total_open=$(gh api "search/issues?q=repo:${owner}/${repo}+type:issue+state:open&per_page=1" \
     --jq '.total_count')
   total_closed=$(gh api "search/issues?q=repo:${owner}/${repo}+type:issue+state:closed&per_page=1" \
     --jq '.total_count')
   total_issues=$((total_open + total_closed))
   ```

   - **< 500 total** (open + closed): Fetch all, paginating fully. Filter out
     excludes during distillation.
   - **500–2000**: Fetch all from value-label and keyword searches (below), plus
     top 100 most-reacted. This gives broad coverage without full enumeration.
   - **> 2000**: Prompt the user with the counts and ask how to proceed. Suggest
     a strategy like: "There are ~3400 issues. I can fetch all labeled
     'answered'/'has workaround' (~180), keyword matches (~250), and top 100
     most-reacted. Or I can paginate through everything (~35 API calls). Which
     do you prefer?"

   #### 5b. Label-based fetches

   For each label in the cached `value-labels` list, fetch all matching issues:
   ```bash
   # Paginate to get all issues with this label, filtering out PRs
   encoded_label=$(printf '%s' "$label_name" | jq -sRr @uri)
   gh api "repos/${owner}/${repo}/issues?labels=${encoded_label}&state=all&per_page=100${since_param}" \
     --paginate --jq '.[] | select(has("pull_request") | not) | "## Issue #\(.number): \(.title)\n\(.body)\n"'
   ```

   #### 5c. Keyword searches

   Search issues/discussions for usage-pattern keywords. These surface "how do
   I...?" and "can I...?" questions that reveal practical workflows:

   **Important:** `gh search issues` returns a JSON array per call. Pipe each
   call through `jq` individually to emit JSONL — do NOT append raw arrays
   with `>>` (creates invalid JSON when concatenated).

   ```bash
   keywords=("how" "can I" "workflow" "workaround" "example" "recipe" "pattern")

   for kw in "${keywords[@]}"; do
     gh search issues "${kw}" --repo "${owner}/${repo}" --sort reactions \
       --json number,title,body,labels,reactions --limit 50 2>/dev/null \
       | jq -c '.[] | {number, title, body: (.body // "" | .[0:2000]), labels: [.labels[].name]}' \
       >> "$tmp_dir/keyword-issues.jsonl" 2>/dev/null || true
   done
   ```

   For repos with Discussions enabled, also search discussions:
   ```bash
   for kw in "${keywords[@]}"; do
     gh api graphql -f query='
       query {
         search(query: "repo:'"${owner}/${repo}"' \"'"${kw}"'\" is:discussion",
                type: DISCUSSION, first: 50) {
           nodes {
             ... on Discussion {
               number title body url
               answer { body }
               labels(first:10) { nodes { name } }
             }
           }
         }
       }' --jq '.data.search.nodes[] | @json' >> "$tmp_dir/keyword-discussions.jsonl" 2>/dev/null || true
   done
   ```

   #### 5d. Reaction-sorted fallback

   Also fetch top most-reacted issues as a catch-all for popular content that
   keyword and label searches might miss:
   ```bash
   gh search issues --repo "${owner}/${repo}" --sort reactions --order desc --state all \
     --limit 100 --json number,title,body,labels,reactions \
     --jq '.[] | {number, title, body: (.body // "" | .[0:2000]), labels: [.labels[].name], reactions: .reactions.total_count}'
   ```

   #### 5e. Deduplicate and filter

   Merge all fetched issues/discussions by number. Remove duplicates. Apply
   `exclude-issue-patterns` to titles (case-insensitive). The final set is what
   gets distilled into the reference doc.

   For each issue/discussion, capture: number, title, body, labels, and
   reaction count. Issues with answers (from Discussions) or resolution
   comments from maintainers are especially valuable — note the resolution.

6. **Extract Local Notes** from the existing reference doc (if it exists).
   Parse all lines from the one that starts with `<!-- BEGIN LOCAL NOTES` through
   the one that starts with `<!-- END LOCAL NOTES` (inclusive of those full marker
   lines, which may include trailing text and the closing `-->`). Store this block
   verbatim — it must be spliced back into the regenerated doc unchanged.

7. **Read all fetched content** and distill into a reference doc with this
   structure:

   ```markdown
   ---
   repo: owner/repo
   repo-head: <sha>
   repo-indexed: <date>
   wiki-head: <sha or null>
   wiki-indexed: <date or null>
   issues-indexed: <date or null>
   discussions-indexed: <date or null>
   labels-indexed: <date>
   label-head: <sha256 of sorted label names>
   doc-sources:
     - path: "<relative path in repo>"
       type: repo-file
       relevance: "<why this file matters>"
     - url: "<external URL>"
       type: external
       relevance: "<why this link matters>"
       reachable: true
   exclude-issue-patterns:
     - "renovate"
     - "dependabot"
     - "bump version"
     - "release v"
   value-labels:
     - name: "<label>"
       reason: "<why this label surfaces useful content>"
   issue-stats:
     total-fetched: <n>
     from-labels: <n>
     from-keywords: <n>
     from-reactions: <n>
     after-dedup: <n>
   ---

   # <Tool Name> Reference

   Distilled from <repo URL>, updated <date>.

   ## Overview

   <1-2 paragraph summary of what the tool does and why>

   ## Installation & Setup

   <How to install, configure, prerequisites>

   ## Core Concepts

   <Key mental models needed to use the tool effectively>

   ## Command Reference

   <Commands with practical examples, grouped by workflow>

   ## Recipes

   <Concrete step-by-step patterns for common tasks, written as numbered
   procedures. These should be copy-pasteable workflows, not abstract
   descriptions. Focus on:

   - The happy path for each common operation
   - How to recover from mistakes
   - Integration with other tools (git-branchless + git-absorb, etc.)>

   ## Anti-Patterns

   <Common mistakes and what to do instead>

   ## Integration

   <How this tool works with the other stacked workflow tools>

   <!-- BEGIN LOCAL NOTES — preserved across regeneration -->

   ## Local Notes

   Hard-won lessons, workarounds, and patterns discovered through actual usage.
   This section is never overwritten by index-repo-docs. Add entries here when
   you solve a pain point or discover undocumented behavior.

   <!-- END LOCAL NOTES -->
   ```

8. **Write the draft to a temp file** — never directly to the reference doc.
   ```bash
   # e.g. ${tmp_dir}/draft.md
   ```

9. **Present a change summary for user review.** Do NOT write the final doc
   until the user approves. Show, in this order:

   1. **Additions** — new sections, recipes, gotchas, anti-patterns
   2. **Changes** — modified sections (briefly describe what changed)
   3. **Removals** — any sections, recipes, or gotchas from the old doc that
      are absent in the draft (flag these prominently — removals need
      justification)
   4. **Stats** — line count old vs new, recipe count old vs new, issue-ref
      (`#NNN`) count old vs new

   If there are removals, explain why each one was dropped. The user may
   reject the draft or ask for revisions. Only proceed to step 10 after
   explicit approval.

10. **Write the approved doc** to the reference file path.

11. **Clean up**:
    ```bash
    rm -rf "$tmp_dir"
    ```

12. **Report** what was generated (full/incremental/skipped), how many source
    files were read, and the output path.

## Guidelines

- Focus on PRACTICAL recipes over theoretical documentation
- Every recipe should be a numbered procedure someone can follow
- Include the exact commands, not just descriptions
- Call out gotchas and edge cases from issues/discussions
- Aim for under 500 lines — this is a reference, not a textbook. But never
  drop existing content to hit the target. If a doc grows past 500 due to
  issue insights, that's acceptable. Condense prose, not information.
- If the wiki has workflow guides, prioritize those over API docs
- Preserve and extend `exclude-issue-patterns` across runs — never shrink it
- Preserve and extend `value-labels` across runs — only remove a label if it
  no longer exists in the repo
- Always re-check labels every run (they're cheap API calls), even if
  everything else is up to date
- When distilling issues, prioritize those with answers or maintainer responses
  — these are confirmed patterns, not just questions
- The `issue-stats` in frontmatter help the user understand coverage on future
  runs — always keep them accurate
- **Local Notes are sacred** — never modify, reorder, or omit content between
  the marker lines that start with `<!-- BEGIN LOCAL NOTES` and `<!-- END LOCAL NOTES`
  during regeneration. Extract before rewriting, then splice the original block back
  verbatim.
- When you solve a pain point or discover undocumented behavior for a tool that
  has a reference doc, add it to that doc's Local Notes section. Format each
  entry as a `### <short title>` with the problem, solution, and context.
- If a Local Notes entry is later confirmed by upstream docs (e.g., after a
  re-index pulls it into a generated section), keep the local note too — it
  may have context the upstream version lacks
