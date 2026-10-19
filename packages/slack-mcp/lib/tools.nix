# The app manifest's input, keyed by the tool rows of Slack's documented scope
# table (`extracted.tools`: row -> scopes): which rows' user scopes the app
# requests, and which of those scopes to leave out. It grants nothing at the
# client; per-tool approval is the pool's generic concern.
{lib}: let
  inherit (import ./extracted.nix {inherit lib;}) tools;
  inherit (lib) mkOption types;
  rows = builtins.attrNames tools;
in {
  option = mkOption {
    default = {};
    description = "Which documented Slack tool rows the app manifest requests scopes for.";
    type = types.submodule {
      options = {
        omitScopes = mkOption {
          type = types.listOf (types.enum (lib.unique (lib.concatLists (builtins.attrValues tools))));
          default = [];
          description = "Scopes left out of the app manifest even when a selected row lists them (for example `im:history`); the row then sees less.";
        };
        rows = mkOption {
          type = types.listOf (types.enum rows);
          default = rows;
          description = "Rows of Slack's tool-to-scope table whose user scopes the app requests. Default: every row.";
        };
      };
    };
  };

  # The user scopes the selected rows need, sorted, less `omitScopes`.
  scopes = cfg:
    lib.subtractLists cfg.omitScopes (lib.naturalSort (lib.unique (lib.concatMap (row: tools.${row}) cfg.rows)));
}
