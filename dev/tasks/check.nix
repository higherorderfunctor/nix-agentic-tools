# dev/tasks/check.nix — local validation tasks that need network/auth
# and therefore cannot run in the CI sandbox / flake checks.
_: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
  log = ''log() { echo "==> $*" >&2; }'';
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

        # ── Copilot ─────────────────────────────────────────────────────
        # No list-models command exists (V8 bytecode SEA). Manual curation
        # only — design doc §5.3. No automated check.
        log "Copilot: no list-models command — manual curation only (skipped)"

        log "Model staleness check complete"
      '';
    };
  };
}
