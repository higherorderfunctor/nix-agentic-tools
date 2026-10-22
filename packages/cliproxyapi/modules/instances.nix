# `ai.cliproxyapi.instances.<name>`: CLIProxyAPI daemons, the same on both
# backends apart from the default state root. The config is rendered at each
# start from the typed settings; CLIProxyAPI's own rewrites of it (the hashed
# management key, management API saves) reach only that copy. Its auth
# directory holds the OAuth logins it writes, so it lives in `stateDir`.
# CLIProxyAPI fetches its model catalogs and its management panel from the
# network unprompted; both default off here (see docs/cliproxyapi-settings.md).
backend: {
  config,
  lib,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cliproxyapi;
in {
  imports = [
    ((import ../../ai-module/lib/instances.nix {inherit lib;}).module {
      # `--local-model` is the only switch for the model catalog fetches: it
      # selects the embedded catalogs, and no setting selects the embedded catalogs.
      arguments = instance:
        ''--config "$CPA_CONFIG"''
        + lib.optionalString (!instance.fetchModelCatalogs) " --local-model";
      inherit backend;
      defaultPort = 8317;
      derived = {instance, ...}: {
        # Without this the daemon downloads its control panel from GitHub at
        # start and every 3 hours after.
        management.disable-auto-update-panel = lib.mkDefault true;
        oauth.auth-dir = "${instance.stateDir}/auth";
        server = {
          host = lib.mkDefault "127.0.0.1";
          inherit (instance) port;
        };
      };
      directories = instance: ["${instance.stateDir}/auth"];
      extraOptions.fetchModelCatalogs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the daemon fetches its model catalogs from
          raw.githubusercontent.com and models.router-for.me at start and every
          3 hours. Off, it runs with `--local-model` and serves the catalogs
          embedded in the package; a `settings.models.*` source still takes
          precedence.
        '';
      };
      owner = "cliproxyapi";
      packagePath = "generic.cliproxyapi";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.cliproxyapi";
      inherit (cliproxyapi) render settingsType;
      tool = "CLIProxyAPI";
      variable = "CPA_CONFIG";
    })
  ];

  # Plugin executors choose credentials outside access.key-allowlist, and the
  # plugin host hands any plugin every auth file through host.auth.get, so
  # enabling plugins voids the allowlist (docs/cliproxyapi-key-allowlist.md).
  # A rule with kind = "oauth" and base-urls can never match: base-urls compare
  # an API-key credential's base_url and an OAuth login is never matched by one.
  # The ids and base-urls types check definitions, so a list whose elements all
  # sit under a false mkIf passes them and merges to [], which CPA reads as
  # unrestricted; the assertion checks the merged value. The same holds for
  # null entries in the allowlist itself: the renderer drops them, so a list of
  # only nulls renders as [], which switches enforcement off for every key. No
  # type refines that list, since the generator refuses a refinement row on a
  # node with a secret descendant (the entry's api-key), so the assertion
  # refuses any null entry.
  config.assertions = lib.concatLists (lib.mapAttrsToList (name: instance: let
    setting = path: lib.attrByPath path null instance.settings;
    present = lib.filter (item: item != null);
    allowlist = lib.defaultTo [] (setting ["access" "key-allowlist"]);
    rules = lib.concatMap (entry: present (lib.defaultTo [] entry.credentials)) (present allowlist);
    emptied = field: lib.filter (rule: rule.${field} == []) rules;
    unmatchable = lib.filter (rule: rule.kind == "oauth" && lib.defaultTo [] rule."base-urls" != []) rules;
  in
    lib.optionals instance.enable ([
        {
          assertion = setting ["plugins" "enabled"] != true || lib.elem (setting ["access" "key-allowlist"]) [null []];
          message = "ai.cliproxyapi.instances.${name}: settings.plugins.enabled = true voids settings.access.key-allowlist: plugin executors choose credentials outside it and can read every credential through host.auth.get. Disable plugins or drop the allowlist.";
        }
        {
          assertion = !(lib.elem null allowlist);
          message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist has a null entry, which the renderer drops: a list of only nulls renders as [] and switches enforcement off for every key. Remove the null entry, or set the list to [] to switch the allowlist off.";
        }
        {
          assertion = unmatchable == [];
          message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist has a rule with kind = \"oauth\" and base-urls, which can never match: base-urls compare an API-key credential's base URL and never match an OAuth login. Use kind = \"apikey\" or drop base-urls.";
        }
      ]
      ++ map (field: {
        assertion = emptied field == [];
        message = "ai.cliproxyapi.instances.${name}: settings.access.key-allowlist[].credentials[].${field} merged to an empty list, which CPA reads as no restriction on that dimension and admits every credential of the provider and kind. Leave the option unset to leave it unrestricted, or list at least one value.";
      }) ["base-urls" "ids"]))
  config.ai.cliproxyapi.instances);
}
