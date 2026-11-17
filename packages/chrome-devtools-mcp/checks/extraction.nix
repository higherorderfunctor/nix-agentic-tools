# Drift and shape checks for the committed direct-option census. The fixture
# exercises the extractor before the owner check does, because a regeneration
# can otherwise turn a collapsed extraction into the new committed truth.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks =
    {
      chrome-devtools-mcp-extract-conflicts = let
        # Computed groups prove this consumes the export's value, not literals
        # found by searching source text. Include an alias's canonical key.
        source = pkgs.writeText "conflicting-mcp-options.mjs" ''
          export const mcpOptions = {
            allowUnrestrictedPaths: {type: "boolean"},
            filesystemRoot: {alias: "workspace", string: true, type: "array"},
            isolated: {type: "boolean"},
          };
          const group = Object.keys(mcpOptions);
          export const CONFLICTING_ARGS = [group];
        '';
        invalid = let
          case = value: message: {inherit message value;};
        in [
          (case "undefined" "must be a non-empty array of groups")
          (case "[]" "must be a non-empty array of groups")
          (case "[42]" "must contain at least two options")
          (case "[['isolated']]" "must contain at least two options")
          (case "[['isolated', 'unknown']]" "names an unknown option unknown")
          (case "[['isolated', 42]]" "names an unknown option 42")
          (case "[['isolated', 'isolated']]" "repeats an option")
        ];
        refuse = test: let
          broken = pkgs.writeText "broken-conflicts.mjs" ''
            export const mcpOptions = {isolated: {type: "boolean"}};
            export const CONFLICTING_ARGS = ${test.value};
          '';
        in ''
          if ${lib.getBin pkgs.nodejs_22}/bin/node ${../extract/mcp-options.mjs} ${broken} >actual.json 2>actual.err; then
            echo "FAIL: malformed conflict groups unexpectedly extracted" >&2
            exit 1
          fi
          grep -F ${lib.escapeShellArg test.message} actual.err
        '';
      in
        pkgs.runCommand "chrome-devtools-mcp-extract-conflicts" {
          nativeBuildInputs = [pkgs.gnugrep pkgs.jq];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${lib.getBin pkgs.nodejs_22}/bin/node ${../extract/mcp-options.mjs} ${source} >actual.json
          jq -e '.cli.conflicts.mcp == [["allowUnrestrictedPaths", "filesystemRoot", "isolated"]]' actual.json
          ${lib.concatMapStringsSep "\n" refuse invalid}
          touch "$out"
        '';

      # A yargs map member that is not an option object cannot be trusted as a
      # settings record. This fails an extractor that serializes whatever it
      # finds and relies on readers to notice the malformed option later.
      chrome-devtools-mcp-extract-refuses-non-object = let
        source = pkgs.writeText "broken-mcp-options.mjs" ''
          export const mcpOptions = {broken: 42};
        '';
      in
        pkgs.runCommand "chrome-devtools-mcp-extract-refuses-non-object" {
          nativeBuildInputs = [pkgs.gnugrep];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          if ${lib.getBin pkgs.nodejs_22}/bin/node ${../extract/mcp-options.mjs} ${source} >actual.json 2>actual.err; then
            echo "FAIL: a non-object yargs option unexpectedly extracted" >&2
            exit 1
          fi
          grep -F 'mcpOptions.broken is not an object' actual.err
          touch "$out"
        '';
    }
    // (extractedLib {inherit pkgs;}).mkOwnerCheck {
      dir = ../extracted;
      name = "chrome-devtools-mcp";
      extracted.x86_64-linux = self.ciPackages.x86_64-linux.chrome-devtools-mcp.passthru.extracted;
      needs = [
        {
          key = "cli.conflicts.mcp";
          contains = ["userDataDir" "isolated"];
        }
        {
          key = "cli.options.mcp.executablePath.alias";
          value = "e";
        }
        {
          key = "cli.options.mcp.executablePath.type";
          value = "string";
        }
        {
          key = "cli.options.mcp.userDataDir.type";
          value = "string";
        }
        {
          key = "cli.options.mcp.usageStatistics.default";
          value = true;
        }
        {
          key = "cli.options.mcp.usageStatistics.type";
          value = "boolean";
        }
        {
          key = "cli.options.mcp.performanceCrux.default";
          value = true;
        }
        {
          key = "cli.options.mcp.performanceCrux.type";
          value = "boolean";
        }
        {
          key = "cli.options.mcp.redactNetworkHeaders.default";
          value = false;
        }
        {
          key = "cli.options.mcp.redactNetworkHeaders.type";
          value = "boolean";
        }
        {
          key = "cli.options.mcp.screenshotFormat.choices";
          value = ["jpeg" "png" "webp"];
        }
        {
          key = "cli.options.mcp.screenshotFormat.type";
          value = "string";
        }
        {
          key = "cli.options.mcp.screenshotMaxWidth.coerce";
          value = {
            function = {
              name = "coerce";
              source = lib.concatStringsSep "\n" [
                "(value) => {"
                "            if (value === undefined) {"
                "                return;"
                "            }"
                "            if (!Number.isInteger(value) || value <= 0) {"
                "                throw new Error(`Invalid screenshotMaxWidth \${value}. Expected a positive integer.`);"
                "            }"
                "            return value;"
                "        }"
              ];
            };
          };
        }
        {
          key = "cli.options.mcp.screenshotMaxWidth.type";
          value = "number";
        }
        {
          key = "cli.options.mcp.filesystemRoot.alias";
          value = "workspace";
        }
        {
          key = "cli.options.mcp.filesystemRoot.default";
          value = ["/tmp"];
        }
        {
          key = "cli.options.mcp.filesystemRoot.defaultDescription";
          value = "OS temp directory";
        }
        {
          key = "cli.options.mcp.filesystemRoot.string";
          value = true;
        }
        {
          key = "cli.options.mcp.filesystemRoot.type";
          value = "array";
        }
      ];
    };
}
