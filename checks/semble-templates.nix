# Drift and review gates for Semble's upstream agent-integration content.
# Extraction reads the pinned package output in a separate derivation; the
# Semble derivation itself stays byte-for-byte identical to llm-agents.nix.
{
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  semble = self.packages.${system}.semble;
  committed = ../packages/semble/upstream-templates.json;
  reviewed = import ../packages/semble/lib/templateCoverage.nix;
  records = import ../packages/semble/lib/integrations.nix;
  snapshot = builtins.fromJSON (builtins.readFile committed);
  templateNames = ["claude.md" "codex.toml" "copilot.md" "kiro.md"];

  extracted = pkgs.runCommand "semble-upstream-templates.json" {nativeBuildInputs = [pkgs.python3];} ''
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

  hash = builtins.hashString "sha256";
  reviewedTemplateNames = builtins.attrNames reviewed.templates;
  snapshotTemplateNames = builtins.attrNames snapshot.templates;
  exactNames = expected: actual: builtins.sort builtins.lessThan expected == builtins.sort builtins.lessThan actual;
  recordShapeIsValid = record: builtins.attrNames record == ["disposition" "reviewedHash"];
  templateHashesMatch = lib.all (name: reviewed.templates.${name}.reviewedHash == hash snapshot.templates.${name}) templateNames;
  reviewedSurface =
    lib.mapAttrs (_: tool: {
      arguments = builtins.attrNames (tool.inputSchema.properties or {});
      required = builtins.sort builtins.lessThan (tool.inputSchema.required or []);
    })
    snapshot.mcpTools;

  pinMarker = "semble[mcp]==";
  pinnedVersionParts = lib.splitString pinMarker snapshot.instructions;
  pinnedVersion =
    if lib.length pinnedVersionParts < 2
    then null
    else lib.head (lib.splitString "\"" (lib.elemAt pinnedVersionParts 1));

  declaredPromptDependenciesCovered = lib.all (tool:
    reviewed.mcpSurface.reviewedTools ? ${tool}
    && lib.all
    (argument: lib.elem argument reviewed.mcpSurface.reviewedTools.${tool}.arguments)
    records.mcpTools.${tool})
  (builtins.attrNames records.mcpTools);
  mcpPrompt = builtins.readFile ../packages/semble/mcp-agent-instructions.md;
  promptMentionsDeclaredDependencies = lib.all (tool:
    lib.hasInfix "`mcp__semble__${tool}`" mcpPrompt
    && lib.all (argument: lib.hasInfix "`${argument}`" mcpPrompt) records.mcpTools.${tool})
  (builtins.attrNames records.mcpTools);
in {
  semble-template-coverage = assert lib.assertMsg (snapshot.schemaVersion == 3) "Semble template snapshot has an unsupported schemaVersion";
  assert lib.assertMsg (exactNames templateNames snapshotTemplateNames) "Semble template snapshot does not contain the exact reviewed template set";
  assert lib.assertMsg (exactNames templateNames reviewedTemplateNames) "Semble template coverage does not classify the exact upstream template set";
  assert lib.assertMsg (builtins.attrNames reviewed.mcpSurface == ["disposition" "reviewedTools"]) "Semble MCP surface coverage must contain exactly disposition and reviewedTools";
  assert lib.assertMsg (lib.all (name: recordShapeIsValid reviewed.templates.${name}) templateNames) "Every Semble template coverage record must contain exactly disposition and reviewedHash";
  assert lib.assertMsg templateHashesMatch "A Semble agent template changed; review the derivative and update templateCoverage.nix";
  assert lib.assertMsg (pinnedVersion != null) "Semble installer instructions no longer embed a `${pinMarker}` package version";
  assert lib.assertMsg (pinnedVersion == snapshot.package.version) "Semble installer instructions pin ${pinMarker}${pinnedVersion} but the packaged version is ${snapshot.package.version}";
  assert lib.assertMsg (reviewed.mcpSurface.reviewedTools == reviewedSurface) "The Semble MCP tools/list surface changed; review packages/semble/mcp-agent-instructions.md and update templateCoverage.nix";
  # Natural-language prompt correctness remains a review obligation. These two
  # assertions mechanically join its declared dependencies, literal references,
  # and the complete reviewed tools/list contract without pretending to parse
  # arbitrary prose.
  assert lib.assertMsg declaredPromptDependenciesCovered "A declared Semble MCP prompt dependency is absent from the reviewed surface";
  assert lib.assertMsg promptMentionsDeclaredDependencies "packages/semble/mcp-agent-instructions.md omits a declared Semble MCP tool or argument";
    pkgs.runCommand "semble-template-coverage" {} ''
      echo "ok — every pinned Semble template has a reviewed content disposition" > "$out"
    '';

  semble-templates-extracted =
    pkgs.runCommand "semble-templates-extracted-drift" {
      passthru = {inherit extracted;};
    } ''
      if ${pkgs.jq}/bin/jq -e -n --slurpfile actual ${extracted} \
        --slurpfile committed ${committed} '$actual == $committed' > /dev/null; then
        echo "ok — packages/semble/upstream-templates.json matches the pinned package" > "$out"
      else
        echo "FAIL: packages/semble/upstream-templates.json is out of sync with the pinned Semble package." >&2
        echo "Regenerate: nix build .#checks.${system}.semble-templates-extracted.passthru.extracted --no-link --print-out-paths" >&2
        echo "Then copy the result over packages/semble/upstream-templates.json and format it." >&2
        exit 1
      fi
    '';
}
