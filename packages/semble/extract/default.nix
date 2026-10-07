{
  lib,
  pkgs,
}: semble: let
  sembleScript = import ../checks/semble-script.nix pkgs;
  templateNames = ["claude.md" "codex.toml" "copilot.md" "kiro.md"];
in {
  inherit templateNames;
  extracted = pkgs.runCommand "semble-extracted.json" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${sembleScript "extract-languages" semble ./extract-languages.py} > "$out"
  '';
  extractedTemplates = pkgs.runCommand "semble-upstream-templates.json" {nativeBuildInputs = [pkgs.python3];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    agent_dir=""
    for candidate in ${semble}/lib/python*/site-packages/semble/agents; do
      [ -d "$candidate" ] || continue
      if [ -n "$agent_dir" ]; then
        echo "FAIL: found multiple Semble agent template directories" >&2
        exit 1
      fi
      agent_dir="$candidate"
    done

    if [ -z "$agent_dir" ]; then
      echo "FAIL: could not find Semble's version-independent agents directory" >&2
      exit 1
    fi

    for template in ${lib.escapeShellArgs templateNames}; do
      if [ ! -f "$agent_dir/$template" ]; then
        echo "FAIL: missing Semble agent template: $template" >&2
        exit 1
      fi
    done

    installer_home="$TMPDIR/installer-home"
    instructions_file="$installer_home/.claude/CLAUDE.md"
    HOME="$installer_home" ${semble}/bin/semble install \
      --agent claude \
      --type instructions \
      --yes

    if [ ! -s "$instructions_file" ]; then
      echo "FAIL: Semble installer wrote no Claude instructions" >&2
      exit 1
    fi

    probe_home="$TMPDIR/probe-home"
    mkdir -p "$probe_home"
    HOME="$probe_home" HF_HUB_OFFLINE=1 \
      python3 ${./semble-mcp-surface.py} ${semble}/bin/semble-mcp > mcp-surface.json

    ${pkgs.jq}/bin/jq -n \
      --arg pname "${semble.pname}" \
      --arg version "${semble.version}" \
      --rawfile instructions "$instructions_file" \
      --rawfile claude "$agent_dir/claude.md" \
      --rawfile codex "$agent_dir/codex.toml" \
      --rawfile copilot "$agent_dir/copilot.md" \
      --rawfile kiro "$agent_dir/kiro.md" \
      --slurpfile mcpTools mcp-surface.json \
      '{
        instructions: $instructions,
        mcpTools: $mcpTools[0],
        package: { pname: $pname, version: $version },
        schemaVersion: 3,
        templates: {
          "claude.md": $claude,
          "codex.toml": $codex,
          "copilot.md": $copilot,
          "kiro.md": $kiro
        }
      }' > "$out"
  '';
}
