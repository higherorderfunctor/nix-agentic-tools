# The committed direct-option census drives this server's typed settings and
# argv renderer. Every extracted option has one classification row; hidden
# upstream internals are refused here rather than exposed as public options.
{lib}: let
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  inherit (facts.load {dir = ../extracted;}) aggregate;
  options = facts.children aggregate "cli.options.mcp.<name>";

  setting = name: flag: {inherit name flag;};
  excluded = reason: {inherit reason;};

  classification = {
    acceptInsecureCerts = setting "acceptInsecureCerts" "--acceptInsecureCerts";
    allowUnrestrictedPaths = setting "allowUnrestrictedPaths" "--allowUnrestrictedPaths";
    allowedUrlPattern = setting "allowedUrlPattern" "--allowedUrlPattern";
    autoConnect = setting "autoConnect" "--autoConnect";
    blockedUrlPattern = setting "blockedUrlPattern" "--blockedUrlPattern";
    browserUrl = setting "browserUrl" "--browserUrl";
    categoryDebugging = setting "categoryDebugging" "--categoryDebugging";
    categoryEmulation = setting "categoryEmulation" "--categoryEmulation";
    categoryExperimentalThirdParty = setting "categoryExperimentalThirdParty" "--categoryExperimentalThirdParty";
    categoryExperimentalWebmcp = setting "categoryExperimentalWebmcp" "--categoryExperimentalWebmcp";
    categoryExtensions = setting "categoryExtensions" "--categoryExtensions";
    categoryInput = setting "categoryInput" "--categoryInput";
    categoryMemory = setting "categoryMemory" "--categoryMemory";
    categoryNavigation = setting "categoryNavigation" "--categoryNavigation";
    categoryNetwork = setting "categoryNetwork" "--categoryNetwork";
    categoryNetworkMocks = setting "categoryNetworkMocks" "--categoryNetworkMocks";
    categoryPerformance = setting "categoryPerformance" "--categoryPerformance";
    categoryPwa = setting "categoryPwa" "--categoryPwa";
    categoryWebauthn = setting "categoryWebauthn" "--categoryWebauthn";
    channel = setting "channel" "--channel";
    chromeArg = setting "chromeArg" "--chromeArg";
    clearcutEndpoint = excluded "hidden telemetry endpoint";
    clearcutForceFlushIntervalMs = excluded "hidden telemetry test interval";
    clearcutIncludePidHeader = excluded "hidden telemetry test header";
    config = setting "config" "--config";
    devtoolsComments = excluded "hidden work-in-progress tool surface";
    executablePath = setting "executablePath" "--executablePath";
    experimentalDataFormat = excluded "hidden experimental structured-data format";
    experimentalDevtools = setting "experimentalDevtools" "--experimentalDevtools";
    experimentalFfmpegPath = setting "experimentalFfmpegPath" "--experimentalFfmpegPath";
    experimentalIncludeAllPages = setting "experimentalIncludeAllPages" "--experimentalIncludeAllPages";
    experimentalInteropTools = excluded "hidden experimental interoperability tools";
    experimentalScreencast = setting "experimentalScreencast" "--experimentalScreencast";
    experimentalStructuredContent = setting "experimentalStructuredContent" "--experimentalStructuredContent";
    experimentalToonFormat = excluded "hidden deprecated alias of experimentalDataFormat";
    experimentalVision = setting "experimentalVision" "--experimentalVision";
    fileNavigations = setting "fileNavigations" "--fileNavigations";
    filesystemRoot = setting "workspace" "--workspace";
    headless = setting "headless" "--headless";
    ignoreDefaultChromeArg = setting "ignoreDefaultChromeArg" "--ignoreDefaultChromeArg";
    isolated = setting "isolated" "--isolated";
    javascriptEvaluation = setting "javascriptEvaluation" "--javascriptEvaluation";
    logFile = setting "logFile" "--logFile";
    maxNavigationSaved = setting "maxNavigationSaved" "--maxNavigationSaved";
    memoryDebugging = setting "memoryDebugging" "--memoryDebugging";
    pageIdRouting = setting "pageIdRouting" "--pageIdRouting";
    performanceCrux = setting "performanceCrux" "--performanceCrux";
    proxyServer = setting "proxyServer" "--proxyServer";
    redactNetworkHeaders = setting "redactNetworkHeaders" "--redactNetworkHeaders";
    screencastFps = setting "screencastFps" "--screencastFps";
    screenshotFormat = setting "screenshotFormat" "--screenshotFormat";
    screenshotMaxHeight = setting "screenshotMaxHeight" "--screenshotMaxHeight";
    screenshotMaxWidth = setting "screenshotMaxWidth" "--screenshotMaxWidth";
    screenshotQuality = setting "screenshotQuality" "--screenshotQuality";
    slim = setting "slim" "--slim";
    sourceMaps = setting "sourceMaps" "--sourceMaps";
    usageStatistics = setting "usageStatistics" "--usageStatistics";
    userDataDir = setting "userDataDir" "--userDataDir";
    viaCli = excluded "hidden marker Chrome DevTools CLI sets when it launches the server";
    viewport = setting "viewport" "--viewport";
    watchConfig = setting "watchConfig" "--watchConfig";
    wsEndpoint = setting "wsEndpoint" "--wsEndpoint";
    wsHeaders = setting "wsHeaders" "--wsHeaders";
  };

  settings = lib.filterAttrs (_: row: row ? name) classification;
  scalarType = {
    boolean = "bool";
    number = "number";
    string = "string";
  };

  # These rows refine yargs' `number` to the integer bounds its coercion
  # functions enforce before a value reaches the server.
  numberRefinements = {
    maxNavigationSaved = {
      type = "number";
      refine = {types, ...}: types.ints.between 1 25;
    };
    screencastFps = {
      type = "number";
      refine = {types, ...}: types.ints.positive;
    };
    screenshotMaxHeight = {
      type = "number";
      refine = {types, ...}: types.ints.positive;
    };
    screenshotMaxWidth = {
      type = "number";
      refine = {types, ...}: types.ints.positive;
    };
    screenshotQuality = {
      type = "number";
      refine = {types, ...}: types.ints.between 0 100;
    };
  };

  # argv cannot express an empty or null-only list: it renders no flag, and
  # upstream then applies its own default. So every list setting refuses one.
  listRefinements = lib.mapAttrs' (_: row:
    lib.nameValuePair row.name {
      type = "list";
      refine = {types, ...}:
        types.nonEmptyListOf types.str
        // {description = "non-empty list of strings (an empty list renders no flag, so upstream's default applies)";};
    }) (lib.filterAttrs (key: _: options.${key}.type == "array") settings);

  # A browser choice must be usable: upstream's coercions treat an empty
  # browserUrl or wsEndpoint as unset, which would restore the implicit Chrome
  # lookup the browser-choice rule refuses, and reject a malformed URL or a
  # wsEndpoint without ws:// or wss://.
  stringRefinements = {
    browserUrl = {
      type = "string";
      refine = {types, ...}: types.strMatching "[A-Za-z][A-Za-z0-9+.-]*:.+";
    };
    executablePath = {
      type = "string";
      refine = {types, ...}: types.nonEmptyStr;
    };
    wsEndpoint = {
      type = "string";
      refine = {types, ...}: types.strMatching "wss?://.+";
    };
  };

  refinements = numberRefinements // listRefinements // stringRefinements;

  nodeOf = key: row: let
    record = options.${key};
    type =
      if record.type == "array"
      then "list"
      else scalarType.${record.type} or (throw "chrome-devtools-mcp option ${key} has unsupported extracted type ${record.type}");
    description = record.description or record.describe or null;
    node =
      {inherit type;}
      // lib.optionalAttrs (description != null) {inherit description;}
      // lib.optionalAttrs (record ? choices) {enum = record.choices;};
  in
    throwIf (record.type == "array" && record.string != true)
    "chrome-devtools-mcp option ${key} is an array whose elements are not strings"
    // {
      ${row.name} = node;
    }
    // lib.optionalAttrs (record.type == "array") {
      "${row.name}[]".type = "string";
    };

  throwIf = condition: message:
    if condition
    then throw message
    else {};

  nodes = lib.foldl' (all: key: all // nodeOf key settings.${key}) {} (builtins.attrNames settings);
  generated = import ../../../lib/extracted/options.nix {inherit lib;} {
    inherit nodes refinements;
    tool = "chrome-devtools-mcp";
  };

  missing = have: lack:
    lib.sort builtins.lessThan (lib.subtractLists lack have);
  report =
    {
      malformedClassification =
        missing
        (lib.filter (key: let
          row = classification.${key};
        in
          !(
            (row ? name && row ? flag && builtins.isString row.name && builtins.isString row.flag && builtins.length (builtins.attrNames row) == 2)
            || (row ? reason && builtins.isString row.reason && builtins.length (builtins.attrNames row) == 1)
          ))
        (builtins.attrNames classification))
        [];
      staleClassification = missing (builtins.attrNames classification) (builtins.attrNames options);
      unclassifiedOptions = missing (builtins.attrNames options) (builtins.attrNames classification);
      unprovenRefinements =
        lib.sort builtins.lessThan
        (lib.filter (key: !(options.${key} ? coerce)) (builtins.attrNames numberRefinements));
    }
    // generated.report;

  renderValue = value:
    if builtins.isBool value
    then lib.boolToString value
    else toString value;

  argsOf = values:
    lib.concatLists (map (key: let
      row = classification.${key};
      value = values.${row.name};
    in
      if value == null
      then []
      else if options.${key}.type == "array"
      then map (item: "${row.flag}=${item}") value
      else ["${row.flag}=${renderValue value}"])
    (lib.sort (left: right: classification.${left}.flag < classification.${right}.flag) (builtins.attrNames settings)));
  # With none of these, upstream looks for Google Chrome at fixed system paths
  # (/opt/google/chrome on Linux) and fails on the first tool call where it is
  # absent, as on NixOS. Refuse that implicit lookup at evaluation instead.
  browserChoices = ["autoConnect" "browserUrl" "executablePath" "wsEndpoint"];
  choosesBrowser = values:
    lib.any (name: let value = values.${name}; in value != null && value != false) browserChoices;
in {
  settingsOptions = generated.options;

  # Common MCP `timeout` is an external-http-entry field. A stdio child has no
  # per-server timeout here, so no such setting is fabricated below it.
  settingsToArgs = values:
    if choosesBrowser values
    then argsOf values
    else throw "chrome-devtools-mcp: choose a browser: set settings.executablePath to launch one, or settings.browserUrl, settings.wsEndpoint or settings.autoConnect to connect to a running Chrome";

  report =
    if lib.all (list: list == []) (builtins.attrValues report)
    then report
    else throw "chrome-devtools-mcp extracted option classification drift: ${builtins.toJSON report}";
}
