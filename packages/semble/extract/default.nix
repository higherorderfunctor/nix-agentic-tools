{pkgs}: semble: let
  sembleScript = import ../checks/semble-script.nix pkgs;
in {
  extracted = pkgs.runCommand "semble-extracted" {nativeBuildInputs = [pkgs.python3];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${sembleScript "extract-languages" semble ./extract-languages.py} > languages.json
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
      --arg version "${semble.version}" \
      --rawfile instructions "$instructions_file" \
      --rawfile claude "$agent_dir/claude.md" \
      --rawfile codex "$agent_dir/codex.toml" \
      --rawfile copilot "$agent_dir/copilot.md" \
      --rawfile kiro "$agent_dir/kiro.md" \
      --slurpfile languages languages.json \
      --slurpfile mcpTools mcp-surface.json \
      '$languages[0] + {
        instructions: $instructions,
        mcpTools: $mcpTools[0],
        templates: {
          "claude.md": $claude,
          "codex.toml": $codex,
          "copilot.md": $copilot,
          "kiro.md": $kiro
        },
        version: $version
      }' > "$out"
  '';
}
