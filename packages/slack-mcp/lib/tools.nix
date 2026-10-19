# The app manifest's input, keyed by the tool rows of Slack's documented scope
# table (`extracted.tools`: row -> scopes): which rows' user scopes the app
# requests (read rows by default, write rows opt in), and which of those
# scopes to leave out. It grants nothing at the
# client; per-tool approval is the pool's generic concern.
{lib}: let
  inherit (import ./extracted.nix {inherit lib;}) tools;
  inherit (lib) mkOption types;
  writes = row: lib.any (lib.hasSuffix ":write") tools.${row};
  rows = lib.partition writes (builtins.attrNames tools);
  readRows = rows.wrong;
  writeRows = rows.right;
in {
  option = mkOption {
    description = "Which documented Slack tool rows the app manifest requests scopes for.";
    type = types.submodule {
      options = {
        omitScopes = mkOption {
          type = types.listOf (types.enum (lib.unique (lib.concatLists (builtins.attrValues tools))));
          default = [];
          description = "Scopes left out of the app manifest even when a selected row lists them (for example `im:history`); the row then sees less.";
        };
        reads = mkOption {
          type = types.listOf (types.enum readRows);
          default = readRows;
          description = "Rows of Slack's tool-to-scope table with no `:write` scope whose user scopes the app requests. Default: every read row.";
        };
        writes = mkOption {
          type = types.listOf (types.enum writeRows);
          default = [];
          description = "Rows of Slack's tool-to-scope table with a `:write` scope whose user scopes the app requests. Opt in: default none.";
        };
      };
    };
  };

  # The user scopes the selected rows need, sorted, less `omitScopes`.
  scopes = cfg:
    lib.subtractLists cfg.omitScopes (lib.naturalSort (lib.unique (lib.concatMap (row: tools.${row}) (cfg.reads ++ cfg.writes))));
}
