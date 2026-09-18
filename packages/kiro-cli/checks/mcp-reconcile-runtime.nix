{
  lib,
  pkgs,
  harness,
}: let
  inherit (harness) evalDevenv evalHm;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) dvMcpTaskExec hmMcpPruneScript hmMcpWriteScript renderedMcpJson;
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
  # Home Manager delivers BOTH modes as the same pair of entries now — the
  # prune phase before checkLinkTargets, the write phase after linkGeneration —
  # so replaying a generation is that pair in order, whatever the mode. There
  # used to be a third entry (`retire-materialize-kiro-settings`) that merge
  # mode substituted for the prune; `own` expresses that release as the prune
  # phase of one two-target plan.
  script = backend: mode: pool: let
    cfg.ai.kiro = {
      enable = true;
      mcpServers = pool;
      mcpWriteMode = mode;
    };
    hm = evalHm cfg;
  in
    if backend == "hm"
    then hmMcpPruneScript hm + hmMcpWriteScript hm
    else dvMcpTaskExec (evalDevenv cfg);
  first = builtins.fromJSON (renderedMcpJson servers);
  second = builtins.fromJSON (renderedMcpJson reduced);
  corpus = map (backend: {
    name = "kiro-mcp-${backend}";
    configFile = ".kiro/settings/mcp.json";
    inherit first second;
    # The merge target STATES this mode, so the shared corpus asserts the
    # writer imposes it rather than preserving whatever the file had. None of
    # these three generations carries a credential url; the 0600 arm is
    # asserted in mcp-reconcile-runtime.py's `secret` case.
    mode = "0644";
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
          # The shared HM corpus starts without HOME; the devenv renderer
          # anchors on the project root, which has to exist before it can cd
          # there. Remove only this empty fixture directory afterward so the
          # corpus can still assert no side effects.
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
