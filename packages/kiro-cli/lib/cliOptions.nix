# cspell:ignore cwds
# What each option of the pinned kiro-cli's `--help` tables is to this module.
#
# `classification` has one row per option of the three tables extracted into
# `cli.options` (`top`, `chat`, `acp`): a setting this module exposes as
# `ai.kiro.cli.<tier>.<name>`, or an exclusion with its reason. `report` diffs
# the table against the committed extraction in both directions, so a release
# that adds or drops an option shows as a failing check rather than as a flag
# nobody judged. Each setting's type comes from its extracted record, through
# lib/extracted/options.nix (an enum from the help's possible values, a bool for
# a flag that takes none); the wrapper turns a configured value into argv.
#
# This module reads the `--help` tables only. It exposes nothing for an
# environment variable.
{lib}: let
  extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  tables = lib.genAttrs ["acp" "chat" "top"] (tier: extracted.children (import ./kiroAggregate.nix {inherit lib;}).aggregate "cli.options.${tier}.<name>");

  # The closed vocabulary of exclusion reasons; a row naming another is an
  # evaluation error.
  r = lib.genAttrs [
    "duplicates-a-workspace-setting" # a settings key (`chat.defaultModel`, ...) already sets it
    "mode" # changes what a launch is, not how it behaves
    "no-v3-effect" # selects a harness the pinned v3 launch supersedes
    "one-off" # acts once per invocation
    "rejected-on-v3" # the parser or `--agent-engine=v3` refuses it
    "trust-settled" # tool trust is `permissions.yaml` only, never a flag
    "wrapper-owned" # the launcher sets it
  ] (reason: {inherit reason;});
  setting = name: description: {inherit description name;};

  classification = {
    acp = {
      "--agent" = r.rejected-on-v3;
      "--agent-engine" = r.wrapper-owned;
      "--auth-method" = setting "authMethod" "Who answers the v3 engine's access-token requests, passed to `kiro-cli acp` as `--auth-method`. Kiro's own default is `cli`, which uses the kiro-cli login session; `client` forwards the requests to the ACP client.";
      "--effort" = r.rejected-on-v3;
      "--help" = r.one-off;
      "--login" = r.one-off;
      "--model" = r.rejected-on-v3;
      "--trust-all-tools" = r.rejected-on-v3;
      "--trust-tools" = r.rejected-on-v3;
      "--verbose" = r.one-off;
    };
    chat = {
      "--agent" = r.duplicates-a-workspace-setting;
      "--agent-engine" = r.wrapper-owned;
      "--all-cwds" = r.one-off;
      "--cloud" = r.mode;
      "--delete-session" = r.one-off;
      "--effort" = r.duplicates-a-workspace-setting;
      "--format" = r.one-off;
      "--help" = r.one-off;
      "--legacy-ui" = r.no-v3-effect;
      "--list-models" = r.one-off;
      "--list-sessions" = r.one-off;
      "--mode" = setting "mode" "Mode of the V3 agent, passed to `kiro-cli chat` as `--mode`. The help declares `default` and `spec`; the parser does not enforce them, so the type is what refuses another value.";
      "--model" = r.duplicates-a-workspace-setting;
      "--no-interactive" = r.mode;
      "--output-format" = r.mode;
      "--repo" = r.mode;
      "--require-mcp-startup" = setting "requireMcpStartup" "Exit with code 3 when an enabled MCP server fails to start, passed to `kiro-cli chat` as `--require-mcp-startup`. False passes nothing.";
      "--resume" = r.one-off;
      "--resume-id" = r.one-off;
      "--resume-picker" = r.one-off;
      "--session-source" = r.one-off;
      "--sessions" = r.mode;
      "--trust-all-tools" = r.trust-settled;
      "--trust-tools" = r.trust-settled;
      "--trust-workspace" = r.trust-settled;
      "--tui" = r.no-v3-effect;
      "--v2" = r.rejected-on-v3;
      "--v3" = r.wrapper-owned;
      "--verbose" = r.one-off;
      "--wrap" = setting "wrap" "Line wrapping of chat output, passed to `kiro-cli chat` as `--wrap`. Kiro's own default is to detect the terminal; the parser does not enforce the three values, so the type is what refuses another.";
    };
    top = {
      "--agent" = r.duplicates-a-workspace-setting;
      "--cloud" = r.mode;
      "--help" = r.one-off;
      "--legacy-ui" = r.no-v3-effect;
      "--repo" = r.mode;
      "--resume" = r.one-off;
      "--resume-id" = r.one-off;
      "--resume-picker" = r.one-off;
      "--tui" = r.no-v3-effect;
      "--v2" = r.rejected-on-v3;
      "--v3" = r.wrapper-owned;
      "--verbose" = r.one-off;
      "--version" = r.one-off;
    };
  };

  # Tiers that carry settings: the subcommands the wrapper injects into.
  settingTiers = ["acp" "chat"];
  # A row naming an option the extraction lacks is left to `report`.
  settingsOf = tier: lib.filterAttrs (long: row: row ? name && tables.${tier} ? ${long}) classification.${tier};
  # The extracted record behind a setting row.
  recordOf = tier: long: tables.${tier}.${long};
  nodeOf = tier: long: row: let
    record = recordOf tier long;
  in
    {inherit (row) description;}
    // (
      if record.takesValue
      then {type = "string";} // lib.optionalAttrs (record.possibleValues != []) {enum = record.possibleValues;}
      else {type = "bool";}
    );
  generated = lib.genAttrs settingTiers (tier:
    import ../../../lib/extracted/options.nix {inherit lib;} {
      nodes = lib.mapAttrs' (long: row: lib.nameValuePair row.name (nodeOf tier long row)) (settingsOf tier);
      tool = "kiro-cli";
    });
  # Every row against the extraction: options with no row, and rows whose option
  # the extraction lacks, as `<tier> <option>`. Both lists are empty for a
  # current table.
  reportOf = {
    classification,
    tables,
  }: let
    missing = have: lack:
      lib.sort builtins.lessThan (lib.concatMap (tier: map (long: "${tier} ${long}") (lib.subtractLists (lack tier) (have tier))) (lib.attrNames tables));
    classified = tier: lib.attrNames classification.${tier};
    measured = tier: lib.attrNames tables.${tier};
  in {
    stale = missing classified measured;
    unclassified = missing measured classified;
  };
in {
  inherit classification reportOf;

  # `ai.kiro.cli.<tier>.<name>` options, every one `nullOr` with default null.
  options = lib.mapAttrs (_: tier: tier.options) generated;

  report = reportOf {inherit classification tables;};

  # The top-level options that act once per invocation: a bare launch carrying
  # one is not rewritten to `chat` (`--version`, `--help`, `--resume-picker`'s
  # top-only `--list` alias, ...). Records for `idempotentFlags.optionPatterns`.
  # `--help-all` is hidden, so no help table lists it; it is root-only and
  # `chat` rejects it, so it is named here beside the classified ones.
  oneOffTopOptions =
    lib.mapAttrsToList (long: record: {
      flag = long;
      inherit (record) aliases short takesValue;
    }) (lib.filterAttrs (long: _: (classification.top.${long} or null) == r.one-off) tables.top)
    ++ [
      {
        flag = "--help-all";
        takesValue = false;
      }
    ];

  # The argv words a configured `values` (`{<tier>.<name> = value;}`, as in
  # `cfg.cli`) adds, per tier, as records for `idempotentFlags.injectOptionsBlock`.
  # An unset or false option adds nothing.
  injections = values:
    lib.genAttrs settingTiers (tier:
      lib.concatLists (lib.mapAttrsToList (long: row: let
        value = lib.attrByPath [tier row.name] null values;
        record = recordOf tier long;
      in
        lib.optional (value != null && value != false) {
          inherit (record) aliases short takesValue;
          flag = long;
          token =
            if record.takesValue
            then "${long}=${value}"
            else long;
        }) (settingsOf tier)));

  # The option path of every setting (for the `package = null` warning).
  paths = lib.concatMap (tier: map (row: ["ai" "kiro" "cli" tier row.name]) (lib.attrValues (settingsOf tier))) settingTiers;
}
