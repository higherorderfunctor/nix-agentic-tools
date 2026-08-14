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

    # The MCP tool surface, read off the wire. This is what
    # `packages/semble/mcp-agent-instructions.md` teaches an agent to call, so
    # it is a real local dependency on upstream rather than a copy of upstream
    # prose. HOME is redirected and HF_HUB_OFFLINE set so the server's model
    # pre-load fails fast instead of retrying against a network the sandbox
    # does not have; the pre-load is a background task whose failure is caught,
    # and stdio serving never waits on it.
    HOME="$TMPDIR/probe-home" HF_HUB_OFFLINE=1 \
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
        schemaVersion: 2,
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

  # PROVENANCE, asserted mechanically rather than reviewed. Upstream's
  # installer text embeds a pinned `semble[mcp]==X.Y.Z` for its non-Nix `uvx`
  # fallback. Nothing previously bound that token to the version actually
  # shipped, so a release that forgot to bump it — or bumped it wrongly — would
  # have passed the moment a reviewer stamped the new hash.
  pinMarker = "semble[mcp]==";
  pinnedVersionParts = lib.splitString pinMarker snapshot.instructions;
  pinnedVersion =
    if lib.length pinnedVersionParts < 2
    then null
    else lib.head (lib.splitString "\"" (lib.elemAt pinnedVersionParts 1));

  # Every tool and argument `mcp-agent-instructions.md` names must exist in the
  # reviewed surface. This is what ties the prompt to the review: the exact
  # match below decides WHEN a human looks, and this decides that the prompt is
  # still calling something real once they have.
  promptToolsCovered =
    lib.all (
      tool:
        reviewed.mcpSurface.reviewedTools ? ${tool}
        && lib.all (argument: lib.elem argument reviewed.mcpSurface.reviewedTools.${tool}.arguments) records.mcpTools.${tool}
    ) (builtins.attrNames records.mcpTools);
in {
  semble-template-coverage = assert lib.assertMsg (snapshot.schemaVersion == 2) "Semble template snapshot has an unsupported schemaVersion";
  assert lib.assertMsg (exactNames templateNames snapshotTemplateNames) "Semble template snapshot does not contain the exact reviewed template set";
  assert lib.assertMsg (exactNames templateNames reviewedTemplateNames) "Semble template coverage does not classify the exact upstream template set";
  assert lib.assertMsg (lib.all (name: recordShapeIsValid reviewed.templates.${name}) templateNames) "Every Semble template coverage record must contain exactly disposition and reviewedHash";
  assert lib.assertMsg templateHashesMatch "A Semble agent template changed; review the derivative and update templateCoverage.nix";
  assert lib.assertMsg (pinnedVersion != null) "Semble installer instructions no longer embed a `${pinMarker}` version; the provenance assert has nothing to check — review templateCoverage.nix";
  assert lib.assertMsg (pinnedVersion == snapshot.package.version) "Semble installer instructions pin ${pinMarker}${pinnedVersion} but the packaged version is ${snapshot.package.version}";
  assert lib.assertMsg (reviewed.mcpSurface.reviewedTools == snapshot.mcpTools) "The Semble MCP tool surface changed; review packages/semble/mcp-agent-instructions.md against the new tools and update templateCoverage.nix";
  assert lib.assertMsg promptToolsCovered "packages/semble/mcp-agent-instructions.md references a Semble MCP tool or argument that the reviewed surface does not contain";
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
