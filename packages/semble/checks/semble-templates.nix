# Drift and review gates for Semble's upstream agent-integration content.
# Both snapshots are built by the package's passthru extractors.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkDriftCheck;
    semble = self.ciPackages.${system}.semble;
    committed = ../upstream-templates.json;
    reviewed = import ../lib/templateCoverage.nix;
    records = import ../lib/integrations.nix;
    snapshot = builtins.fromJSON (builtins.readFile committed);
    templateNames = ["claude.md" "codex.toml" "copilot.md" "kiro.md"];

    extracted = semble.passthru.extractedTemplates;

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
    mcpPrompt = builtins.readFile ../mcp-agent-instructions.md;
    promptMentionsDeclaredDependencies = lib.all (tool:
      lib.hasInfix "`mcp__semble__${tool}`" mcpPrompt
      && lib.all (argument: lib.hasInfix "`${argument}`" mcpPrompt) records.mcpTools.${tool})
    (builtins.attrNames records.mcpTools);
  in
    {
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
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          echo "ok — every pinned Semble template has a reviewed content disposition" > "$out"
        '';
    }
    // mkDriftCheck {
      inherit committed extracted;
      name = "semble-templates";
      sidecar = "packages/semble/upstream-templates.json";
    };
}
