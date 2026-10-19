# `ai.jail` / `ai.<runtime>.jail` (lib/ai/jail): the root-to-runtime fold, the
# in-place jail at the install seam, and the two warnings. bubblewrap is
# Linux-only, so the lowering checks are absent on Darwin and the Darwin
# warning contract is absent on Linux.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest mkWrapperGrepTest;
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
  backends = ["devenv" "hm"];

  excludePaths = ["/home/test/.claude/.credentials.json" "/home/test/.ssh"];
  claudeJail = {
    enable = true;
    exclude = {
      environment = ["SSH_AUTH_SOCK"];
      paths = excludePaths;
    };
  };
  enabled = runtimes: lib.genAttrs runtimes (_: {enable = true;});
  jailedClaude.ai.claude = {
    enable = true;
    jail = claudeJail;
  };
  bwrap = lib.getExe pkgs.bubblewrap;
in {
  checks =
    {
      # Copilot ships no launcher, so it does not consume the surface: a root
      # request warns through the standard delivery diagnostic.
      module-ai-jail-copilot-warns = mkTest "ai-jail-copilot-warns" (
        lib.all (backend:
          builtins.elem
          "ai.jail is set but ${backend} does not deliver it to copilot (reason: copilot's surfaceSupport does not consume this shared surface.)"
          (warningsOf backend {
            ai = {
              copilot.enable = true;
              jail.enable = true;
            };
          }))
        backends
      );
    }
    // lib.optionalAttrs isLinux {
      # Pure evaluation of the lowering, on both backends.
      module-ai-jail = mkTest "ai-jail" (
        lib.all (backend: let
          plain = installed backend {ai.claude.enable = true;};
          jailedPackages = installed backend jailedClaude;
          jailed = jailOf "claude" jailedPackages;
          script = jailed.jails.claude;
          # Text matching compares bytes; store-path context is irrelevant.
          text = builtins.unsafeDiscardStringContext script.text;
          both = installed backend {ai = enabled ["claude" "codex"] // {jail.enable = true;};};
          optedOut = installed backend {
            ai = {
              claude = {
                enable = true;
                jail.enable = false;
              };
              codex.enable = true;
              jail.enable = true;
            };
          };
          codexPlain = installed backend {ai.codex.enable = true;};
        in
          # The jailed launcher replaces the plain one under the same name,
          # carrying the masks, the unset variable and the exclusion base.
          jailed
          != null
          && outPaths jailedPackages != outPaths plain
          && builtins.attrNames jailed.jails == ["claude"]
          && script.destination == "/bin/claude"
          && lib.all (needle: lib.hasInfix (builtins.unsafeDiscardStringContext needle) text) ([bwrap "--unsetenv SSH_AUTH_SOCK" "--chdir" "--dev-bind / /"] ++ excludePaths)
          && !(lib.hasInfix "--clearenv" text)
          && !(lib.any (lib.hasInfix "Linux-only") (warningsOf backend jailedClaude))
          # The root enables every consuming runtime ...
          && jailOf "claude" both != null
          && jailOf "codex" both != null
          && builtins.attrNames (jailOf "codex" both).jails == ["codex" "codex-code-mode-host"]
          # ... and a runtime `enable = false` keeps that one plain.
          && jailOf "claude" optedOut == null
          && jailOf "codex" optedOut != null
          && lib.elem (builtins.head (outPaths plain)) (outPaths optedOut)
          # Off everywhere, including a set exclude list without `enable`,
          # installs exactly what it did before the surface existed.
          && outPaths (installed backend {
            ai = {
              claude.enable = true;
              jail.exclude.paths = excludePaths;
            };
          })
          == outPaths plain
          && outPaths (installed backend {ai.codex.enable = true;}) == outPaths codexPlain)
        backends
      );

      # Builds the jailed launcher, which runs the wrapper's shellcheck, and
      # reads the installed `bin/claude` through the profile's symlink.
      module-ai-jail-wrapper = mkWrapperGrepTest {
        name = "ai-jail-wrapper";
        package = jailOf "claude" (installed "hm" jailedClaude);
        bin = "claude";
        needles = [bwrap "--unsetenv SSH_AUTH_SOCK" "--chdir"] ++ excludePaths;
        # `no-new-session` keeps the controlling terminal.
        absentNeedles = ["--clearenv" "--new-session"];
      };
    }
    // lib.optionalAttrs isDarwin {
      module-ai-jail-darwin-warns = mkTest "ai-jail-darwin-warns" (
        lib.all (backend:
          builtins.elem
          "ai.claude.jail is enabled but bubblewrap is Linux-only; nothing is jailed on ${system}."
          (warningsOf backend jailedClaude)
          && outPaths (installed backend jailedClaude) == outPaths (installed backend {ai.claude.enable = true;}))
        backends
      );
    };
}
