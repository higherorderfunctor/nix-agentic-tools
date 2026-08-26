# dev/tasks/check.nix — local validation tasks that need network/auth
# and therefore cannot run in the CI sandbox / flake checks.
{pkgs ? null, ...}: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
  log = ''log() { echo "==> $*" >&2; }'';

  # The nixpkgs whose `lib` the grammar surface is evaluated against. Pinned by
  # store path rather than reached through `<nixpkgs>`, so the task checks the
  # surface against the same lib the flake builds with instead of whatever
  # channel happens to be on the caller's NIX_PATH.
  nixpkgsPath =
    if pkgs == null
    then "<nixpkgs>"
    else pkgs.path;

  # `checks` is a per-system flake output, so an arm deferring to one has to
  # name the system. Baked in when `pkgs` is available; otherwise left as a
  # command substitution the task resolves at run time, rather than guessing.
  systemAttr =
    if pkgs == null
    then "$(nix eval --impure --raw --expr builtins.currentSystem)"
    else pkgs.stdenv.hostPlatform.system;
in {
  tasks = {
    "check:model-staleness" = {
      description = "Compare committed model lists against each CLI's live list-models (local, authed)";
      exec = ''
        ${bashPreamble}
        ${log}

        # ── Kiro (needs AWS SSO + network) ──────────────────────────────
        log "Kiro: querying live model catalog"
        kiro_json=$(kiro-cli chat --list-models -f json 2>/dev/null || true)
        if [ -z "$kiro_json" ]; then
          log "Kiro: no output (not authed / offline) — SKIPPED"
        else
          # Stub-guard: the offline degraded payload is auto-only. Treat as
          # not-authed; do NOT report drift (avoids a false positive).
          only_auto=$(printf '%s' "$kiro_json" \
            | jq -r '[.models[].model_name] == ["auto"]' 2>/dev/null || echo false)
          model_ids=$(printf '%s' "$kiro_json" \
            | jq -r '.models[].model_id' 2>/dev/null | sort -u || true)
          if [ "$only_auto" = "true" ] || [ -z "$model_ids" ]; then
            log "Kiro: offline auto-only stub detected — SKIPPED (not a drift)"
          else
            committed=$(jq -r '.[]' packages/kiro-cli/models.json | sort -u)
            missing=$(comm -23 <(printf '%s\n' "$model_ids") <(printf '%s\n' "$committed") || true)
            if [ -z "$missing" ]; then
              log "Kiro: OK — packages/kiro-cli/models.json covers the live catalog"
            else
              log "Kiro: DRIFT — live ids missing from packages/kiro-cli/models.json:"
              printf '    %s\n' $missing >&2
            fi
          fi
        fi

        # ── Claude ──────────────────────────────────────────────────────
        # Nothing to do here. Claude's model ids are pulled out of the
        # packaged binary by vu.mkClaudeExtract into the committed
        # overlays/claude-code-extracted.json, so they are covered by the
        # blocking claude-code-extracted drift check in `nix flake check`
        # — no live catalog, no auth, no curation.
        log "Claude: covered by the claude-code-extracted drift check (skipped)"

        # ── Copilot ─────────────────────────────────────────────────────
        # No list-models command exists (V8 bytecode SEA). Manual curation
        # only — design doc §5.3. No automated check.
        log "Copilot: no list-models command — manual curation only (skipped)"

        log "Model staleness check complete"
      '';
    };

    # The acceptance list of SLICE-GRAMMAR-FROM-NIX, in one command.
    # (packages/strictdoc-grammar/docs/implementation-brief.md, "Acceptance".)
    #
    # THIS TASK IS THE CONVENIENCE COPY, NOT THE GATE. The same acceptance list
    # is wired into `nix flake check` as `checks/strictdoc-grammar-*.nix`, which
    # is this repository's validation entrypoint; the arms below are the local
    # fast path over the working tree, where the flake checks read `${self}` and
    # so only ever see committed bytes. Do not read the two as alternatives —
    # when they disagree, the flake check is right and this one is stale. (An
    # earlier revision of this comment claimed "nothing here can run in CI" and
    # "milestone 1 wires no CI on purpose". Both were true when it was written
    # and neither is now.)
    #
    # Every step below is a gate, and the two that could pass vacuously carry a
    # POSITIVE CONTROL beside them: the model comparator is shown to report a
    # difference between two grammars that really differ, and each negative
    # fixture must fail. A gate that cannot fail is not a gate.
    #
    # Acceptance item 3 — "the DSL cannot weaken the types" — is deliberately
    # NOT reimplemented here. It is a differential (a weakening must be rejected
    # WITH the type check and accepted by the emitter alone, or the rejection
    # proves nothing), its case table lives in
    # `checks/strictdoc-grammar-surface-live.nix`, and a second copy of that
    # table is exactly the drift this comment is warning about. The arm below
    # defers to that check instead.
    "check:sdoc-grammar" = {
      description = "Gate the typed .sgra grammar surface: surfaces current, models equal, fixtures fail";
      exec = ''
        ${bashPreamble}
        ${log}
        cd "$DEVENV_ROOT"

        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        rc=0
        fail() { echo "    FAIL: $*" >&2; rc=1; }

        extract=packages/strictdoc-grammar/extract
        fixtures=packages/strictdoc-grammar/fixtures

        # Render one DSL value file to a `.sgra`. `--impure` is needed for the
        # working-tree paths, not for nixpkgs — that is pinned above.
        render() {
          nix eval --raw --impure --expr "
            let lib = import ${nixpkgsPath}/lib;
                g = import ./packages/strictdoc-grammar/lib {inherit lib;};
            in g.render (import ./$1 {inherit (g) dsl;})"
        }

        # ── 1/2. The two generated surfaces are current ─────────────────
        log "extract.py --check (faithful surface matches strictdoc's grammar)"
        strictdoc-grammar-extract "$extract/extract.py" \
          --output packages/strictdoc-grammar/lib/faithful.nix --check \
          || fail "faithful.nix is stale — run generate:sdoc-grammar"
        log "normalize.py --check (normalized surface matches faithful)"
        strictdoc-grammar-extract "$extract/normalize.py" --check \
          || fail "normalized.nix is stale — run generate:sdoc-grammar"

        # ── 4/5. This repository's five node types ──────────────────────
        # SEMANTIC equality is the correctness gate; byte-identity is the
        # regression gate. Both are reported, and they fail separately.
        log "rendering packages/strictdoc-grammar/values.nix"
        render packages/strictdoc-grammar/values.nix > "$work/grammar.sgra" \
          || fail "values.nix does not render"
        # `>&2` because devenv shows a task's stderr and swallows its stdout, and
        # a semantic gate whose PASS is invisible reads exactly like one that
        # never ran.
        strictdoc-grammar-extract "$extract/compare.py" \
          docs/sdoc/grammar.sgra "$work/grammar.sgra" >&2 \
          || fail "the rendered grammar parses to a DIFFERENT model than docs/sdoc/grammar.sgra"
        if diff -u docs/sdoc/grammar.sgra "$work/grammar.sgra"; then
          log "byte-identical to docs/sdoc/grammar.sgra"
        else
          fail "byte diff against docs/sdoc/grammar.sgra (shown above)"
        fi

        # ── 7. The foreign grammar round-trips ──────────────────────────
        log "rendering $fixtures/foreign.nix"
        render "$fixtures/foreign.nix" > "$work/foreign.sgra" \
          || fail "foreign.nix does not render"
        strictdoc-grammar-extract "$extract/compare.py" \
          "$fixtures/foreign.sgra" "$work/foreign.sgra" >&2 \
          || fail "the rendered foreign grammar parses to a DIFFERENT model"
        if diff -u "$fixtures/foreign.sgra" "$work/foreign.sgra"; then
          log "byte-identical to $fixtures/foreign.sgra"
        else
          fail "byte diff against $fixtures/foreign.sgra (shown above)"
        fi

        # POSITIVE CONTROL for the comparator. Two grammars that really differ
        # must be reported as differing — otherwise every "models equal" above
        # is worth nothing.
        if strictdoc-grammar-extract "$extract/compare.py" \
             docs/sdoc/grammar.sgra "$fixtures/foreign.sgra" >/dev/null 2>&1; then
          fail "compare.py called two DIFFERENT grammars equal — the semantic gate is inert"
        else
          log "positive control: compare.py separates two different grammars"
        fi

        # ── 3. The generated surface is live ────────────────────────────
        # Deferred, not duplicated — see the header. Without this arm the whole
        # task passes with `lib/check.nix` gutted to the identity function:
        # MEASURED, both files above still render byte-identically, because the
        # emitter reads named keys with `or` defaults and is blind to every
        # weakening the types catch.
        # The flake check reads the flake's own `self`, so it sees COMMITTED
        # bytes rather than the working tree this task otherwise checks. An
        # uncommitted weakening of lib/check.nix will not be caught here until
        # it is staged — which is the one way this arm is weaker than the rest
        # of the task, and the reason it names the command to run by hand.
        live=".#checks.${systemAttr}.strictdoc-grammar-surface-live"
        log "acceptance item 3: deferring to $live"
        if nix build --no-link "$live"; then
          log "surface live: a weakened value is rejected by the types, not by the emitter"
        else
          fail "the generated option surface is INERT — see: nix build -L $live"
        fi

        # ── 6a. Ours, at Nix evaluation ─────────────────────────────────
        # Duplicate field titles and duplicate relation roles have no rule
        # anywhere in strictdoc: each parses clean and exports exit 0, and the
        # silent recovery runs in OPPOSITE directions.
        for fixture in "$fixtures"/negative/*.nix; do
          name=$(basename "$fixture" .nix)
          if nix eval --raw --impure --expr "
               let lib = import ${nixpkgsPath}/lib;
                   g = import ./packages/strictdoc-grammar/lib {inherit lib;};
               in g.render [(import ./$fixture)]" >/dev/null 2>&1; then
            fail "negative fixture $name was ACCEPTED at Nix evaluation"
          else
            log "negative (nix): $name rejected"
          fi
        done

        # ── 6b. StrictDoc's, at export ──────────────────────────────────
        # None of these run on a bare parse: SDocValidator is only ever called
        # from the traceability-index build, so a whole-project export is the
        # only thing that runs them. Each fixture is copied into a throwaway
        # project outside the repository — `IMPORT_FROM_FILE` resolves a bare
        # filename beside the document, and a `.sgra` under the repo root would
        # be read by the repository's OWN export.
        for fixture in "$fixtures"/negative/*.sgra.invalid; do
          name=$(basename "$fixture" .sgra.invalid)
          project="$work/neg-$name"
          mkdir -p "$project"
          cp "$fixture" "$project/g.sgra"
          printf '[DOCUMENT]\nTITLE: Fixture\n\n[GRAMMAR]\nIMPORT_FROM_FILE: g.sgra\n' \
            > "$project/d.sdoc"
          if strictdoc export "$project" --formats=json \
               --output-dir "$work/out-$name" >/dev/null 2>&1; then
            fail "negative fixture $name EXPORTED cleanly"
          else
            log "negative (strictdoc): $name rejected"
          fi
        done

        if [ "$rc" -ne 0 ]; then
          log "grammar surface: FAILED"
          exit 1
        fi
        log "grammar surface: all gates passed"
      '';
    };
  };
}
