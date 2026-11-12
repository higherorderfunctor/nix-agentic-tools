# CPA's opt-in overlap assertions compare selected offers per client key without changing routes.
{
  lib,
  catalog,
  providers,
}: let
  # Stable sets deduplicate repeated routes and model spellings in diagnostics.
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  # Exact canonical ids win; scoped aliases never borrow another vendor's spelling.
  canonical = vendor: spelling: let
    matches = builtins.attrNames (lib.filterAttrs (_: model:
      lib.elem spelling (
        if vendor == null
        then lib.concatLists (builtins.attrValues model.aliases)
        else model.aliases.${vendor} or []
      ))
    catalog.models);
  in
    if catalog.models ? ${spelling}
    then {
      id = spelling;
      errors = [];
    }
    # An undeclared finite spelling still has an identity, but no inferred maker.
    else if matches == []
    then {
      id = spelling;
      errors = [];
    }
    else if lib.length matches == 1
    then {
      id = lib.head matches;
      errors = [];
    }
    # Never choose the first ambiguous alias, including for unscoped custom vendors.
    else {
      id = spelling;
      errors = ["ambiguous model alias `${spelling}`: ${lib.concatStringsSep ", " matches}; use a canonical catalog id."];
    };
  # OAuth membership uses the vendor's maker, not its CPA provider name.
  offers = instance: name: routes: let
    credential = instance.credentials.${name};
    inherit (credential) oauth;
    maker = catalog.vendors.${oauth.vendor}.maker or null;
    finite = map (canonical credential.vendor) (sorted (lib.concatMap (route: route.models) routes));
  in
    if oauth != null
    then {
      # Missing maker metadata cannot silently turn an OAuth offer into an empty set.
      errors = lib.optional (maker == null) "OAuth vendor `${oauth.vendor}` has no catalog maker; declare ai.catalog.vendors.${oauth.vendor}.maker.";
      ids = builtins.attrNames (lib.filterAttrs (_: model: maker != null && model.maker == maker) catalog.models);
    }
    else {
      errors = lib.concatMap (model: model.errors) finite;
      ids = sorted (map (model: model.id) finite);
    };
  # One client selects APIs through the existing resolver, preserving its earlier diagnostics.
  clientErrors = name: instance: clientName: client: let
    path = "ai.cliproxyapi.instances.${name}.clientKeys.${clientName}";
    resolved = map (choice: (providers.route instance "${path}.routes" choice) // {inherit (choice) credential;}) client.routes;
    # Invalid routes and non-harness APIs (including passthrough) do not participate.
    selected = lib.filter (route: !(route ? problem) && (!(route ? api) || providers.apis.${route.api}.harnessApi)) resolved;
    # Grouping unions only this client's selected APIs and collapses duplicate credential routes.
    grouped = lib.groupBy (route: route.credential) selected;
    names = builtins.attrNames grouped;
    exclusive = credential: instance.credentials.${credential}.exclusive;
    normalized = lib.mapAttrs (offers instance) grouped;
    # Compare each distinct pair once, and only when one member opts in.
    pairs = lib.concatMap (left:
      map (right: {inherit left right;}) (lib.filter (right: left < right && (exclusive left || exclusive right)) names))
    names;
    # Report missing maker facts and shared models for one participating credential pair.
    compare = {
      left,
      right,
    }: let
      prefix = "${path}: credentials `${left}` and `${right}`";
      overlapping = lib.intersectLists normalized.${left}.ids normalized.${right}.ids;
      hasOauth = lib.any (credential: instance.credentials.${credential}.oauth != null) [left right];
      finite = lib.concatMap (credential: lib.optionals (instance.credentials.${credential}.oauth == null) normalized.${credential}.ids) [left right];
      # Finite identities need no maker until a participating pair includes OAuth.
      unknown = sorted (lib.filter (id: (catalog.models.${id}.maker or null) == null) finite);
    in
      lib.optionals hasOauth (map (id: "${prefix} cannot compare model `${id}` with OAuth: declare ai.catalog.models.${id}.maker.") unknown)
      # OAuth/OAuth compares actual catalog membership, never hypothetical future models.
      ++ lib.optional (overlapping != []) "${prefix} overlap on canonical models ${lib.concatMapStringsSep ", " (id: "`${id}`") overlapping}; remove an overlapping route or turn off exclusive.";
  in
    # No participating exclusive credential means no catalog validation and unchanged fallback.
    lib.optionals (lib.any exclusive names) (
      lib.concatLists (lib.mapAttrsToList (credential: offer: map (error: "${path}: credential `${credential}`: ${error}") offer.errors) normalized)
      ++ lib.concatMap compare pairs
    );
in
  # Disabled instances impose no overlap policy, even when they contain exclusive credentials.
  name: instance: lib.optionals instance.enable (lib.concatLists (lib.mapAttrsToList (clientErrors name instance) instance.clientKeys))
