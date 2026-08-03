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
  snapshot = builtins.fromJSON (builtins.readFile committed);
  templateNames = ["claude.md" "codex.toml" "copilot.md" "kiro.md"];

  extracted = pkgs.runCommand "semble-upstream-templates.json" {} ''
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

    if [ ! -f "$instructions_file" ]; then
      echo "FAIL: Semble installer did not write Claude instructions" >&2
      exit 1
    fi

    ${pkgs.jq}/bin/jq -n \
      --arg pname "${semble.pname}" \
      --arg version "${semble.version}" \
      --rawfile instructions "$instructions_file" \
      --rawfile claude "$agent_dir/claude.md" \
      --rawfile codex "$agent_dir/codex.toml" \
      --rawfile copilot "$agent_dir/copilot.md" \
      --rawfile kiro "$agent_dir/kiro.md" \
      '{
        instructions: $instructions,
        package: { pname: $pname, version: $version },
        schemaVersion: 1,
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
in {
  semble-template-coverage = assert lib.assertMsg (snapshot.schemaVersion == 1) "Semble template snapshot has an unsupported schemaVersion";
  assert lib.assertMsg (exactNames templateNames snapshotTemplateNames) "Semble template snapshot does not contain the exact reviewed template set";
  assert lib.assertMsg (exactNames templateNames reviewedTemplateNames) "Semble template coverage does not classify the exact upstream template set";
  assert lib.assertMsg (recordShapeIsValid reviewed.instructions) "Semble instructions coverage must contain exactly disposition and reviewedHash";
  assert lib.assertMsg (lib.all (name: recordShapeIsValid reviewed.templates.${name}) templateNames) "Every Semble template coverage record must contain exactly disposition and reviewedHash";
  assert lib.assertMsg (reviewed.instructions.reviewedHash == hash snapshot.instructions) "Semble installer instructions changed; review the derivative and update templateCoverage.nix";
  assert lib.assertMsg templateHashesMatch "A Semble agent template changed; review the derivative and update templateCoverage.nix";
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
