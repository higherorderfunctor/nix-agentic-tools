# Sandbox inference: the guest reaches the runtime's selected CLIProxyAPI
# instance through one factory door, authenticating as a VM-only client whose
# key the host stages per launch (fw_cfg -> guest 0400 file). The guest config
# is exactly the owner lowering's output for the guest selection — phase 6
# carries no consumer native Claude/Codex settings, no host logins and no host
# key references into the guest.
{
  config,
  lib,
  options,
  pkgs,
}: runtime: let
  doors = import ./doors.nix;
  inferenceLib = import ../../../../lib/ai/inference {inherit lib;};
  redact = import ../../../../lib/redact {inherit lib;};
  runtimeNames = import ../../../../lib/ai/runtimes.nix;
  claudeInference = import ../../../claude-code/lib/inference.nix {inherit lib pkgs;};
  codexInference = import ../../../chatgpt-codex/lib/inference.nix {
    inlineToml = import ../../../chatgpt-codex/lib/inlineToml.nix {inherit lib;};
    inherit lib pkgs;
  };
  # Guests route only these two harnesses (modules/common.nix's routes).
  supportedRuntimes = ["claude" "codex"];
  # A settings pool's type always carries an `inference` selection, left null
  # by runtimes that consume none; a namespaced runtime such as Copilot keeps
  # its pool under `ai.<runtime>.<namespace>`, where this flat probe rightly
  # finds nothing to reuse.
  selectsInference = harness:
    builtins.hasAttr harness options.ai
    && builtins.hasAttr "settings" options.ai.${harness}
    && lib.isOption options.ai.${harness}.settings;
  sandboxClient = config.ai.${runtime}.sandbox.inference.clientKey;
  # The host selection the guest reuses, minus its client: a runtime without
  # an inference pool has nothing to reuse.
  hostSelection =
    if selectsInference runtime
    then config.ai.${runtime}.settings.inference
    else {
      clientKey = null;
      instance = null;
      key = null;
      url = null;
    };
  # A disabled runtime's inherited client name requests nothing; an explicit
  # null opts a live sandbox out.
  live = config.ai.${runtime}.enable && config.ai.${runtime}.sandbox.enable;
  requested = live && sandboxClient != null;
  option = "ai.${runtime}.sandbox.inference.clientKey";
  guestSelection = hostSelection // {clientKey = sandboxClient;};
  registry = config.ai.internal.inferenceInstances;
  resolved = inferenceLib.resolve registry guestSelection;
  selectable = requested && hostSelection.instance != null && hostSelection.url == null;
  # The instance's native loopback port, from the owner's own option rather
  # than a parsed URL; a registry entry without the owner module has none.
  instancePort = name:
    if name == null
    then null
    else if builtins.hasAttr "cliproxyapi" options.ai && config.ai.cliproxyapi.instances ? ${name}
    then config.ai.cliproxyapi.instances.${name}.port
    else null;
  port = instancePort hostSelection.instance;
  # A sandbox client an enabled host harness also selects must be refused:
  # revoking it would then cut a host harness too.
  selectsSameClient = harness:
    config.ai.${harness}.enable
    && selectsInference harness
    && (let
      own = config.ai.${harness}.settings.inference;
    in
      own.instance == guestSelection.instance && own.clientKey == sandboxClient);
  hostReuse = lib.filter selectsSameClient runtimeNames;
  active =
    selectable
    && builtins.elem runtime supportedRuntimes
    && resolved != null
    && resolved.backend == "cliproxyapi"
    && port != null;
  # The guest endpoint replaces only origin and key: routes, credentials and
  # backend stay the VM client's own resolution, and the door URL keeps the
  # factory's constants rather than the instance's host origin.
  guestEndpoint =
    resolved
    // {
      key = redact.file "/run/sandbox-inference/key";
      url = "http://${doors.address}:${toString doors.inference}";
    };
  # The owner lowerings return mkDefault-wrapped leaves for module merging;
  # with no consumer values to merge against (phase 6), the guest file is the
  # lowering's own output with the priorities unwrapped.
  plain = lib.mapAttrsRecursiveCond (value: !(value ? _type && value._type == "override")) (_: leaf: leaf.content or leaf);
  claudeGuestSettings = claudeInference.config {
    backend = "hm";
    resolvedInference = guestEndpoint;
  };
  guestSettings =
    if runtime == "claude"
    then plain claudeGuestSettings.ai.claude.native.settings
    else plain (codexInference.settings true guestEndpoint);
in {
  assertions =
    # Generic resolver diagnostics (missing/disabled instance, missing
    # client, external selection) name this option path themselves.
    lib.optionals requested (inferenceLib.assertionsFor registry ["ai" runtime "sandbox" "inference" "clientKey"] guestSelection)
    ++ lib.optional (requested && !(builtins.elem runtime supportedRuntimes)) {
      assertion = builtins.elem runtime supportedRuntimes;
      message = "${option}: sandbox inference supports the claude and codex guest routes only.";
    }
    ++ lib.optional (selectable && resolved != null && resolved.backend != "cliproxyapi") {
      assertion = resolved == null || resolved.backend == "cliproxyapi";
      message = "${option} selects a \`${resolved.backend}\` proxy instance; sandbox inference supports cliproxyapi instances only.";
    }
    ++ lib.optional (selectable && resolved != null && resolved.backend == "cliproxyapi" && port == null) {
      assertion = port != null;
      message = "${option} names \`${hostSelection.instance}\`, which is registered without the cliproxyapi owner module, so its native port is unavailable.";
    }
    ++ lib.optional (active && hostReuse != []) {
      assertion = hostReuse == [];
      message = "${option} names client \`${sandboxClient}\` of instance \`${hostSelection.instance}\`, also selected by ${lib.concatMapStringsSep ", " (harness: "ai.${harness}.settings.inference") hostReuse}; give the sandbox a VM-only client.";
    };
  # Only the factory parameters an active selection needs; everything else
  # (door, blob, probe) stays absent when inference is inactive.
  extension = lib.optionalAttrs active {
    homeFiles =
      if runtime == "claude"
      # writeText, not builtins.toFile: the settings reference the key-helper
      # derivation, and only a derivation may carry another's context.
      then {".claude/settings.json" = pkgs.writeText "claude-sandbox-settings.json" (builtins.toJSON guestSettings);}
      else {".codex/config.toml" = (pkgs.formats.toml {}).generate "codex-sandbox-config.toml" guestSettings;};
    inference = {
      client = sandboxClient;
      inherit (hostSelection) instance;
      inherit (resolved) key;
      option = "ai.${runtime}.sandbox.inference.clientKey";
      inherit port;
    };
  };
}
