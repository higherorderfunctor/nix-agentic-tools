# cspell:ignore unjailed
# `ai.jail` / `ai.<runtime>.jail` (lib/ai/jail): the root-to-runtime fold,
# exclusion restrictions, the in-place jail at the install seam, and the
# platform warning. bubblewrap is Linux-only, so the lowering checks are absent on
# Darwin and the Darwin warning contract is absent on Linux.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm mkTest mkWrapperGrepTest rejectsChange;
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux system;

  evalBackend = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  installed = backend: config: let
    evaluated = (evalBackend backend config).config;
  in
    if backend == "hm"
    then evaluated.home.packages
    else evaluated.packages;
  warningsOf = backend: config: (evalBackend backend config).config.warnings;
  outPaths = map (package: package.outPath);
  jailOf = runtime: packages: lib.findFirst (package: package.name == "${runtime}-jail") null packages;
  forBackends = label: check: checkRows label (lib.genAttrs ["devenv" "hm"] check);

  excludePaths = ["/home/test/.claude/.credentials.json" "/home/test/.ssh"];
  plainCodex.ai.codex.enable = true;
  claudeJail = {
    enable = true;
    exclude = {
      environment = ["SSH_AUTH_SOCK"];
      paths = excludePaths;
    };
  };
  plainClaude.ai.claude.enable = true;
  rootJail.ai = {
    claude.enable = true;
    codex.enable = true;
    jail.enable = true;
  };
  jailedClaude.ai.claude = {
    enable = true;
    jail = claudeJail;
  };
  bwrap = lib.getExe pkgs.bubblewrap;
  codexPlainHm = builtins.head (installed "hm" plainCodex);
  codexJailed = jailOf "codex" (installed "hm" {
    ai.codex = {
      enable = true;
      jail.enable = true;
    };
  });
in {
  checks =
    {
      # Both backends import the same root option declaration.
      module-ai-jail-exclusions = mkTest "ai-jail-exclusions" (
        let
          exclusions = input: (evalHm input).config.ai.jail.exclude;
        in
          checkRows "hm ai.jail.exclude" {
            "environment rejects a name containing =" = rejectsChange (input: (exclusions input).environment) {
              expected = ["SSH_AUTH_SOCK"];
              invalid.ai.jail.exclude.environment = ["SSH_AUTH_SOCK=value"];
              valid.ai.jail.exclude.environment = ["SSH_AUTH_SOCK"];
            };
            "paths reject a relative path" = rejectsChange (input: (exclusions input).paths) {
              expected = ["/home/test/.ssh"];
              invalid.ai.jail.exclude.paths = [".ssh"];
              valid.ai.jail.exclude.paths = ["/home/test/.ssh"];
            };
          }
      );
    }
    // lib.optionalAttrs isLinux {
      # Pure evaluation of the lowering, on both backends.
      module-ai-jail = mkTest "ai-jail" (
        forBackends "jail lowering" (backend: let
          plain = outPaths (installed backend plainClaude);
          plainLauncher =
            if builtins.length plain == 1
            then builtins.head plain
            else null;
          jailedPackages = installed backend jailedClaude;
          both = installed backend rootJail;
          rootCodexJail = jailOf "codex" both;
          optedOut = installed backend (lib.recursiveUpdate rootJail {ai.claude.jail.enable = false;});
          exclusionsOnly = installed backend (lib.recursiveUpdate plainClaude {ai.jail.exclude.paths = excludePaths;});
        in
          checkRows "${backend} Linux jail" {
            # Installed bin names and arguments are checked on the actual
            # built wrappers below.
            "Claude's runtime jail replaces the plain launcher" =
              builtins.length jailedPackages == 1 && jailOf "claude" jailedPackages != null;
            "enabled Claude jail emits no platform warning" =
              !(lib.any (lib.hasInfix "Linux-only") (warningsOf backend jailedClaude));
            "excluding paths without enabling the jail keeps the plain install" = outPaths exclusionsOnly == [plainLauncher];
            "root enable jails Claude" = jailOf "claude" both != null;
            "runtime false keeps Claude plain while Codex stays jailed" =
              rootCodexJail
              != null
              && lib.sort builtins.lessThan (outPaths optedOut) == lib.sort builtins.lessThan [plainLauncher rootCodexJail.outPath];
          })
      );

      # Only the `codex` entry point is jailed; its helper keeps its bin
      # name, with no jail of its own, and runs inside the jail that spawns it.
      module-ai-jail-codex-bins = pkgs.runCommand "ai-jail-codex-bins" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "FAIL: $1" >&2
          exit 1
        }
        test -x ${codexJailed}/bin/codex || fail "jailed package is missing executable bin/codex"
        grep -qF -- ${lib.escapeShellArg bwrap} ${codexJailed}/bin/codex || fail "bin/codex does not launch bubblewrap"
        helper=${codexJailed}/bin/codex-code-mode-host
        test -L "$helper" && test -x "$helper" || fail "codex-code-mode-host is not an executable link"
        test "$helper" -ef ${codexPlainHm}/bin/codex-code-mode-host \
          || fail "codex-code-mode-host does not resolve to the original executable"
        touch "$out"
      '';

      # Builds the jailed launcher, which runs the wrapper's shellcheck, and
      # reads the installed `bin/claude` through the profile's symlink.
      module-ai-jail-wrapper = mkWrapperGrepTest {
        name = "ai-jail-wrapper";
        package = jailOf "claude" (installed "hm" jailedClaude);
        bin = "claude";
        needles = [bwrap "--unsetenv SSH_AUTH_SOCK" "--chdir" "--dev-bind / /"] ++ excludePaths;
        # `no-new-session` keeps the controlling terminal.
        absentNeedles = ["--clearenv" "--new-session"];
      };
    }
    // lib.optionalAttrs isDarwin {
      module-ai-jail-darwin-warns = mkTest "ai-jail-darwin-warns" (
        forBackends "Darwin jail fallback" (backend: let
          plain = outPaths (installed backend plainClaude);
        in
          checkRows "${backend} Darwin jail" {
            "enabled Claude jail leaves the installed package unchanged" =
              builtins.length plain == 1 && outPaths (installed backend jailedClaude) == plain;
            "enabled Claude jail names the unsupported platform" =
              builtins.elem
              "ai.claude.jail is enabled but bubblewrap is Linux-only; nothing is jailed on ${system}."
              (warningsOf backend jailedClaude);
          })
      );
    };
}
