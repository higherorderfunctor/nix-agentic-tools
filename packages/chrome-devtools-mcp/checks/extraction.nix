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
        mkSource = name: options: groups:
          pkgs.writeText "${name}.mjs" ''
            export const mcpOptions = ${options};
            export const CONFLICTING_ARGS = ${groups};
          '';
        options = ''
          {
            allowUnrestrictedPaths: {type: "boolean"},
            filesystemRoot: {alias: "workspace", string: true, type: "array"},
            isolated: {type: "boolean"},
          }
        '';
        # A computed group must be read from the export, not scraped from
        # literals or rewritten to use public aliases instead of canonical keys.
        source = mkSource "computed-conflicts" options "[Object.keys(mcpOptions)]";
        invalid = let
          case = groups: message: {inherit groups message options;};
        in {
          duplicate-member = case "[['isolated', 'isolated']]" "CONFLICTING_ARGS[0] repeats an option";
          empty-groups = case "[]" "CONFLICTING_ARGS must be a non-empty array of groups";
          missing-groups = case "undefined" "CONFLICTING_ARGS must be a non-empty array of groups";
          # A string can pass a length-only check, but it is not a group array.
          non-array-group = case "['isolated']" "CONFLICTING_ARGS[0] must contain at least two options";
          # Reject a non-object yargs option before readers can mistake it for a settings record.
          non-object-option = {
            groups = "[['broken', 'isolated']]";
            message = "mcpOptions.broken is not an object";
            options = ''{broken: 42, isolated: {type: "boolean"}}'';
          };
          # A numeric member must not pass by coercing to a real string key.
          non-string-member = {
            groups = "[['isolated', 42]]";
            message = "CONFLICTING_ARGS[0] names an unknown option 42";
            options = ''{"42": {type: "boolean"}, isolated: {type: "boolean"}}'';
          };
          singleton-group = case "[['isolated']]" "CONFLICTING_ARGS[0] must contain at least two options";
          unknown-member = case "[['isolated', 'unknown']]" "CONFLICTING_ARGS[0] names an unknown option unknown";
        };
        refuse = name: test: let
          broken = mkSource name test.options test.groups;
        in ''
          refuse ${lib.escapeShellArg name} ${broken} ${lib.escapeShellArg test.message}
        '';
      in
        pkgs.runCommand "chrome-devtools-mcp-extract-conflicts" {
          nativeBuildInputs = [pkgs.gnugrep pkgs.jq];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          extract() {
            ${lib.getBin pkgs.nodejs_22}/bin/node ${../extract/mcp-options.mjs} "$1"
          }
          refuse() {
            local name=$1 source=$2 expected=$3
            if extract "$source" >actual.json 2>actual.err; then
              echo "FAIL: $name unexpectedly extracted" >&2
              exit 1
            fi
            if ! grep -Fx "chrome-devtools-mcp-extract: $expected" actual.err; then
              echo "FAIL: $name should report $expected" >&2
              cat actual.err >&2
              exit 1
            fi
          }

          extract ${source} >actual.json
          jq -e '.cli.conflicts.mcp == [["allowUnrestrictedPaths", "filesystemRoot", "isolated"]]' actual.json
          ${lib.concatStrings (lib.mapAttrsToList refuse invalid)}
          touch "$out"
        '';
    }
    // (extractedLib {inherit pkgs;}).mkOwnerCheck {
      dir = ../extracted;
      name = "chrome-devtools-mcp";
      extracted.x86_64-linux = self.ciPackages.x86_64-linux.chrome-devtools-mcp.passthru.extracted;
      # Independent pins for facts consumed as schema or used to justify a
      # public spelling or a local type refinement.
      needs =
        [
          {
            key = "cli.conflicts.mcp";
            contains = ["userDataDir" "isolated"];
          }
        ]
        ++ lib.mapAttrsToList (key: value: {
          key = "cli.options.mcp.${key}";
          inherit value;
        }) {
          "filesystemRoot.alias" = "workspace";
          "screenshotFormat.choices" = ["jpeg" "png" "webp"];
          "screenshotFormat.type" = "string";
          # A change in coercion (even with the same yargs type) needs review
          # against the local positive-integer refinement.
          "screenshotMaxWidth.coerce".function = {
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
    };
}
