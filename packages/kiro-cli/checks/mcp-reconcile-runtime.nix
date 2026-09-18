{
  lib,
  pkgs,
  harness,
}: let
  inherit (harness) evalDevenv evalHm;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) dvMcpTaskExec hmMcpPruneScript hmMcpRetirementScript hmMcpWriteScript renderedMcpJson;
  servers = {
    alpha = {
      type = "http";
      url = "https://alpha.invalid/mcp";
    };
    beta = {
      type = "http";
      url = "https://beta.invalid/mcp";
    };
  };
  reduced = removeAttrs servers ["beta"];
  script = backend: mode: pool: let
    cfg.ai.kiro = {
      enable = true;
      mcpServers = pool;
      mcpWriteMode = mode;
    };
    hm = evalHm cfg;
  in
    if backend == "hm"
    then
      (
        if mode == "merge"
        then hmMcpRetirementScript hm
        else hmMcpPruneScript hm
      )
      + hmMcpWriteScript hm
    else dvMcpTaskExec (evalDevenv cfg);
  first = builtins.fromJSON (renderedMcpJson servers);
  second = builtins.fromJSON (renderedMcpJson reduced);
  corpus = map (backend: {
    name = "kiro-mcp-${backend}";
    configFile = ".kiro/settings/mcp.json";
    inherit first second;
    native = {
      mcpServers = {
        alpha.headers."X-Hand" = "native sibling";
        hand = {url = "https://hand.invalid";};
      };
      native = true;
    };
    scripts = map (
      pool:
        lib.optionalString (backend == "devenv") ''
          export DEVENV_ROOT="$HOME"
          export DEVENV_STATE="''${XDG_STATE_HOME:-$HOME/.local/state}"
          # The shared HM corpus starts without HOME; a devenv project must
          # exist before tasks can cd to it. Remove only this empty fixture
          # directory afterward so the corpus can still assert no side effects.
          ${pkgs.coreutils}/bin/mkdir -p "$DEVENV_ROOT"
        ''
        + script backend "merge" pool
        + lib.optionalString (backend == "devenv") ''
          ${pkgs.coreutils}/bin/rmdir --ignore-fail-on-non-empty "$DEVENV_ROOT"
        ''
    ) [servers reduced {}];
  }) ["hm" "devenv"];
  cases = map (backend: {
    inherit backend first second;
    scripts = {
      failedHelper = script backend "merge" {
        alpha = {
          type = "http";
          url.helper = "./failed-helper";
        };
      };
      merge = script backend "merge" servers;
      mergeEmpty = script backend "merge" {};
      mergeReduced = script backend "merge" reduced;
      overwrite = script backend "overwrite" servers;
      overwriteEmpty = script backend "overwrite" {};
      overwriteReduced = script backend "overwrite" reduced;
      secret = script backend "merge" {
        alpha = {
          type = "http";
          url.file = "credential-url";
          headers.Authorization = {
            file = "unused-header-secret";
            prefix = "Bearer ";
          };
        };
      };
    };
  }) ["hm" "devenv"];
in
  pkgs.runCommand "module-test-kiro-mcp-reconcile-runtime" {} ''
    ${pkgs.python3}/bin/python ${../../claude-code/checks/json-settings-runtime.py} \
      ${pkgs.writeText "kiro-mcp-leaf-corpus.json" (builtins.toJSON corpus)} ${pkgs.bash}/bin/bash
    ${pkgs.python3}/bin/python ${./mcp-reconcile-runtime.py} \
      ${pkgs.writeText "kiro-mcp-transitions.json" (builtins.toJSON cases)} ${pkgs.bash}/bin/bash
    echo 'PASS: kiro-mcp-reconcile-runtime' > "$out"
  ''
