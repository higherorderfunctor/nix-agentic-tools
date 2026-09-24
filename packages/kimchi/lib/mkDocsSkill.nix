# cspell:ignore lndir
# Builds the opt-in `kimchi-docs` skill directory.
#
# Shape: `{ SKILL.md, snapshot -> <kimchi-docs> }`.
#
# ── Symlink, not copy ──
#
# `snapshot` is a single store symlink to the pinned `docs.kimchi-docs`
# derivation, never a copy of its 52 files. Three reasons, in order:
#
#   1. Store-backed skill directories are a supported shape (#1755), so nothing
#      downstream needs the files to live inside this derivation.
#   2. A copy would duplicate the snapshot on every docs bump AND rebuild this
#      derivation's own hash for content it does not own.
#   3. `readlink skill/snapshot` is then a one-line, exact assertion that the
#      skill is wired to the packaged snapshot — which is what
#      `packages/kimchi/checks/docs-skill.nix` checks. A copy can only be
#      compared heuristically.
#
# The link target is an ABSOLUTE store path, so it survives every materialization
# route: Home Manager's `recursive = true` (lndir walks through it),
# `mkDevenvSkillEntries` (`builtins.readDir` reports `symlink`, so the walk emits
# ONE entry for it rather than 52), and Codex's whole-directory link.
#
# `search` selects the search directions spliced into SKILL.md. It is resolved by
# the caller from the semble integration actually delivered to that runtime; see
# `packages/kimchi/modules/common.nix`.
{
  docs,
  lib,
  pkgs,
  search,
}: let
  searchBlocks = {
    cli = ''
      Semble is wired into this session's shell. Prefer it over `grep` for
      "how do I…" questions; fall back to `grep`/`rg` for an exact flag or key
      you can already spell.

      ```bash
      semble search "connect an MCP server" ./snapshot --content docs
      semble search "ferment lifecycle states" ./snapshot --content docs --top-k 10
      ```
    '';
    mcp = ''
      Semble is wired into this session as MCP tools and this runtime has no
      shell. Call `mcp__semble__search` with `repo` set to the `snapshot`
      directory beside this file and `content` set to `"docs"`:

      ```json
      { "query": "connect an MCP server", "repo": "./snapshot", "content": "docs" }
      ```

      Use `mcp__semble__find_related` with a result's `file_path` and `line` to
      reach neighboring pages.
    '';
    plain = ''
      Search the snapshot with an ordinary text search:

      ```bash
      rg -n --glob '*.md' 'mcp' ./snapshot/docs
      ```
    '';
  };
  searchBlock = searchBlocks.${search};

  text = ''
    ---
    name: kimchi-docs
    description: Answer a question about Kimchi itself — the Kimchi CLI, Kimchi Coding, Ferment, Kimchi Inference, the VS Code extension, or any docs.kimchi.dev setting, provider or reporting surface — from a pinned offline snapshot of docs.kimchi.dev. Use only for Kimchi product documentation; it says nothing about any other tool.
    ---

    # Kimchi documentation snapshot

    The `snapshot` directory beside this file is a pinned, offline copy of
    <https://docs.kimchi.dev/>. `snapshot/ATTRIBUTION` records the snapshot date
    and upstream ownership. Everything in it is Markdown.

    **Do not read it wholesale.** It is dozens of pages; reading it as a unit is
    never the right move and is why this skill exists as a search entry point
    instead of as context.

    ## Find the page before you read anything

    The indexes carry one line per page, each with a description, so they answer
    "which page" in a single read:

    - `snapshot/llms.txt` — the section index.
    - `snapshot/docs/llms.txt` — every page, grouped by section.
    - `snapshot/docs/<section>/llms.txt` — one section.

    An index entry's URL maps to a file: `https://docs.kimchi.dev/docs/<page>.md`
    is `snapshot/docs/<page>.md`. Read only the pages the index named.

    ## Search

    The commands below are written relative to this skill's own directory — the
    one holding this `SKILL.md`. Run them from there, or substitute that
    directory's absolute path; never hardcode a store path, because it changes on
    every snapshot update.

    ${lib.removeSuffix "\n" searchBlock}

    ## When this snapshot is the right source, and when it is not

    - Use it for anything upstream documents: CLI flags, settings keys, config
      file shapes, supported providers, reporting surfaces, ACP/LSP/MCP wiring.
    - Use kimchi's own `--help`, or its source, for undocumented behavior and
      for anything that must reflect the installed version rather than the
      snapshot date.
    - The snapshot is pinned and read-only. If it contradicts the installed
      kimchi, say so rather than picking one silently.
  '';
in
  pkgs.runCommand "kimchi-docs-skill-${search}" {
    passthru = {inherit docs search text;};
  } ''
    # Full strict mode is required here: stdenv does not set every flag (#909).
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/install -m 644 ${pkgs.writeText "SKILL.md" text} "$out/SKILL.md"
    ${pkgs.coreutils}/bin/ln -s ${docs} "$out/snapshot"
  ''
