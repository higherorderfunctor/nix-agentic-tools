# A Harness selects a registered proxy instance (with a named client when the
# instance declares clients), or an external CPA origin. Proxy owners register
# instances in `ai.internal.proxyInstances`; the selected instance's backend
# picks the one lowering a runtime runs.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../redact {inherit lib;};
  urlPattern = "https?://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+[]])(:[0-9]+)?";
  urlDescription = "the proxy origin only, `http://<host>:<port>`, with no path";
  selectionOptions = {
    clientKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Named client of the selected Instance, required when the Instance declares clients and refused otherwise; its key and routes belong to that Instance.";
    };
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "main";
      description = "A proxy instance its owner registers, such as an `ai.cliproxyapi.instances` entry, selected with `clientKey` when it declares clients.";
    };
    key = mkOption {
      type = types.nullOr redact.types.redacted;
      default = null;
      description = "Client key for an external `url`, as a redact reference read when the Harness starts.";
    };
    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "External CPA origin, selected with `key`: ${urlDescription}.";
    };
  };
  isSelected = selection: selection.url != null || selection.instance != null;
  # Each field's selector, and the selector of the other form.
  selectorOf = {
    clientKey = "instance";
    instance = "instance";
    key = "url";
    url = "url";
  };
  otherSelector = {
    instance = "url";
    url = "instance";
  };
  # `{entry}` for the enabled instance `name`, or `{problem}` saying why
  # `option` cannot select it.
  lookup = registry: option: name: let
    entry = registry.${name} or null;
  in
    if entry == null
    then {problem = "${option} names `${name}`, which no proxy owner registers; registered instances: ${lib.concatStringsSep ", " (builtins.attrNames registry)}.";}
    else if !entry.enable
    then {problem = "${option} names `ai.${entry.backend}.instances.${name}`, which is disabled.";}
    else {inherit entry;};
  problems = registry: path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
    found = lookup registry "${name}.instance" selection.instance;
  in
    lib.optional (has "url" && has "instance") "${name}.url and ${name}.instance both select a proxy; set one."
    ++ lib.optional (has "url" && !has "key") "${name}.url needs `key`: without one the Harness may send its own login token to CPA."
    ++ lib.optional (has "key" && !has "url") "${name}.key is set without `url`; Instance selections use `clientKey`."
    ++ lib.optional (has "clientKey" && !has "instance") "${name}.clientKey is set without `instance`."
    ++ lib.optionals (has "url") (lib.optional (builtins.match urlPattern selection.url == null) "${name}.url must be ${urlDescription}; got `${selection.url}`.")
    ++ lib.optionals (has "instance") (lib.toList (found.problem or []))
    ++ lib.optionals (has "instance" && found ? entry) (clientProblems name selection found.entry);
  # Only an instance that declares clients takes, and needs, a `clientKey`.
  clientProblems = name: selection: entry: let
    owner = "ai.${entry.backend}.instances.${selection.instance}";
  in
    if entry.clients == null
    then lib.optional (selection.clientKey != null) "${name}.clientKey is set, but `${owner}` declares no clients."
    else if selection.clientKey == null
    then ["${name}.instance needs `clientKey`."]
    else lib.optional (!(builtins.hasAttr selection.clientKey entry.clients)) "${name}.clientKey names `${selection.clientKey}`, which is not a client of `${owner}`.";
  assertionsFor = registry: path: selection:
    map (message: {
      assertion = false;
      inherit message;
    }) (problems registry path selection);
in {
  inherit assertionsFor;
  # `ai.<runtime>.proxy` definitions copying each root field at default
  # priority, so a runtime value wins field by field. A root field is copied
  # as null once the runtime selects the other form (an instance under a root
  # `url`, or the reverse), and the root `clientKey` once the runtime selects
  # another instance that declares no clients; switching clears nothing by
  # hand. Each condition sits inside the value: the definitions themselves
  # never read the runtime selection they define. A copy reads the runtime's
  # other selector only while the root's is null, whose own copy then returns
  # without reading back; `instance` never reads `clientKey`.
  copyDown = registry: root: runtime:
    lib.mapAttrs (field: value:
      lib.mkDefault (
        let
          other = otherSelector.${selectorOf.${field}};
        in
          if value != null && root.${other} == null && runtime.${other} != null
          then null
          else if value != null && field == "clientKey" && runtime.instance != root.instance && runtime.instance != null && (registry.${runtime.instance} or {}).clients or {} == null
          then null
          else value
      ))
    root;
  # A runtime selection with the root fields copied in: checked whole when it
  # selects, otherwise only the fields the runtime changed, so an opt-out
  # ignores what it inherits. An unchanged copy is asserted at `ai.proxy`.
  runtimeAssertionsFor = registry: path: root: selection: let
    own = lib.mapAttrs (field: value:
      if value == root.${field}
      then null
      else value)
    selection;
  in
    lib.optionals (selection != root) (assertionsFor registry path (
      if isSelected selection
      then selection
      else own
    ));
  # The instance's `backend` and `url`, its `trust` when it has one, plus the
  # selected client's attributes when the instance declares clients; null for
  # a selection `problems` refuses. An external `url` is CPA-shaped, so it lowers as `cliproxyapi`.
  resolve = registry: selection: let
    found = lookup registry "" selection.instance;
    endpoint = {inherit (found.entry) backend url;} // lib.optionalAttrs (found.entry.trust != null) {inherit (found.entry) trust;};
    clients = found.entry.clients;
  in
    if !isSelected selection
    then null
    else if selection.instance == null
    then {
      inherit (selection) key url;
      backend = "cliproxyapi";
      credentials = [];
    }
    else if !(found ? entry)
    then null
    else if clients == null
    then
      if selection.clientKey == null
      then endpoint
      else null
    else if selection.clientKey != null && clients ? ${selection.clientKey}
    then clients.${selection.clientKey} // endpoint
    else null;
  # Runs the runtime's lowering for the resolved backend; a runtime without
  # one refuses the selection.
  lower = runtime: lowerings: resolved:
    (lowerings.${resolved.backend}
      or (throw "ai.${runtime}.proxy selects a `${resolved.backend}` proxy instance, which ${runtime} cannot use; it supports ${lib.concatStringsSep ", " (builtins.attrNames lowerings)}."))
    resolved;
  registryOption = mkOption {
    type = types.attrsOf (types.submodule {
      options = {
        backend = mkOption {
          type = types.str;
          description = "The owner that registers the instance, `ai.<backend>`; a runtime runs only this backend's lowering.";
        };
        clients = mkOption {
          type = types.nullOr (types.attrsOf (types.attrsOf types.raw));
          default = null;
          description = "Named clients a selection's `clientKey` picks, whose attributes reach the backend's lowering; null for an instance selected by name alone.";
        };
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether the instance runs; selecting a disabled instance fails evaluation.";
        };
        trust = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = "For an instance that intercepts TLS: an executable printing the path of a PEM bundle a client must trust, the instance's CA after the bundle its optional argument names. It fails when the CA does not exist yet.";
        };
        url = mkOption {
          type = types.strMatching urlPattern;
          description = "The instance's origin without a path.";
        };
      };
    });
    default = {};
    internal = true;
    visible = false;
    description = "Proxy instances by name, added by their owners, who claim each name in `ai.claims.proxy-instance`.";
  };
  rootOption = mkOption {
    type = types.submodule {options = selectionOptions;};
    default = {};
    description = "Point a Harness (Claude Code or Codex CLI) at a proxy instance with `instance` (+ `clientKey` when it declares clients), or at external CPA with `url` + `key`. Each field copies down to `ai.<runtime>.proxy` at default priority, so a runtime value wins field by field; a runtime selecting the other form drops the root's fields of that form. Instance routes select named upstream credentials; no Harness publishes keys or rules.";
  };
  runtimeOptions = selectionOptions;
  resolvedType = types.nullOr (types.submodule {
    freeformType = types.attrsOf types.raw;
    options = {
      backend = mkOption {
        type = types.str;
        description = "The selected instance's backend, whose lowering the runtime runs.";
      };
      url = mkOption {
        type = types.strMatching urlPattern;
        description = "Proxy origin without a path.";
      };
    };
  });
}
