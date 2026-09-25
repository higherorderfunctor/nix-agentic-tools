# `ai.programs.git` / `ai.programs.gh`: a git and GitHub CLI identity per
# harness, delivered as two environment variables on each runtime's internal
# module-env channel — `GIT_CONFIG_GLOBAL` (a store gitconfig) and
# `GH_CONFIG_DIR`. Imported by `sharedOptions.nix`, so Home Manager and devenv
# share this one module and its option tree.
#
# Deliberately NOT here:
# - No write into the user's own `programs.git`. `gitSshConfigWorkaround`
#   does that on Home Manager; an identity must not, or the agent's name
#   would become the user's.
# - No `GH_TOKEN`/`GITHUB_TOKEN`. Copilot CLI prefers either over its own
#   login, so a PAT there breaks Copilot's model access. git reads the token
#   through its credential helper; gh reads `hosts.yml` in `GH_CONFIG_DIR`.
# - Nothing on PATH. Claude's Bash tool re-runs shell init, which can put
#   the real binaries back in front; env vars survive it.
# cspell:ignore gpgsm openpgp
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  credentials = import ../../credentials.nix {inherit lib;};
  moduleEnvironment = import ../module-environment.nix {inherit lib;};
  programFactory = import ../program.nix {inherit lib;};
  harnessNames = import ../runtimes.nix;
  specs = import ./git-options.nix {
    inherit lib;
    inherit (credentials) mkCredentialsOption;
    supportedRuntimes = harnessNames;
  };
  git = programFactory.mkProgram specs.git;
  gh = programFactory.mkProgram specs.gh;

  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;

  # `mkProgram` replaces a leaf when the runtime value is non-null. `settings`
  # is the one exception: a per-harness `user.name` must keep the shared
  # `user.email`, so it deep-merges root then runtime.
  resolveGit = runtime: let
    runtimeSettings = config.ai.${runtime}.programs.git.settings;
  in
    git.resolve config runtime
    // {
      settings =
        lib.recursiveUpdate config.ai.programs.git.settings
        (
          if runtimeSettings == null
          then {}
          else runtimeSettings
        );
    };

  # The signer each format runs, pinned so signing does not depend on PATH.
  # Same programs Home Manager's git module defaults to.
  signers = {
    openpgp = lib.getExe' pkgs.gnupg "gpg";
    ssh = lib.getExe' pkgs.openssh "ssh-keygen";
    x509 = lib.getExe' pkgs.gnupg "gpgsm";
  };

  # git runs an absolute helper path as `<helper> get|store|erase`. Only `get`
  # answers. The secret is read when git asks, so only its PATH is in the
  # store, and the shared reader fails loudly on a missing or empty secret
  # rather than handing git an empty password.
  credentialHelper = secret:
    pkgs.writeShellApplication {
      name = "ai-git-credential-github";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :

        [ "''${1:-}" = get ] || exit 0
        ${credentials.mkSecretAssignment pkgs "ai_git_token" secret}
        printf 'username=x-access-token\npassword=%s\n' "$ai_git_token"
      '';
    };

  # `GIT_CONFIG_GLOBAL` REPLACES both `~/.gitconfig` and the XDG config, so
  # the file includes them. Home Manager knows the XDG root; elsewhere git's
  # own default stands in.
  userConfigs = [
    "~/.gitconfig"
    "${lib.attrByPath ["xdg" "configHome"] "~/.config" config}/git/config"
  ];

  renderGitconfig = runtime: cfg: let
    inherit (cfg) signing;
    derived = lib.foldl' lib.recursiveUpdate {} [
      (lib.optionalAttrs (signing.key != null) {user.signingKey = signing.key;})
      (lib.optionalAttrs (signing.format != null) {
        gpg = {
          inherit (signing) format;
          ${signing.format}.program = signers.${signing.format};
        };
      })
      (lib.optionalAttrs signing.signByDefault {
        commit.gpgSign = true;
        tag.gpgSign = true;
      })
      # The empty value resets the helper list, dropping every helper the
      # included user config set. Without it an agent push that this helper
      # cannot answer falls through to the user's own token.
      (lib.optionalAttrs (cfg.credentials != null) {
        credential."https://github.com".helper = ["" (lib.getExe (credentialHelper cfg.credentials))];
      })
    ];
    body = lib.recursiveUpdate derived cfg.settings;
  in
    # Two renders, concatenated. `toGitINI` sorts sections, which would put
    # `[commit]`, `[credential …]` and `[gpg]` BEFORE `[include]` — and since
    # the last value wins, the user's included config would then override the
    # agent's signing and re-append the user's credential helper after the
    # reset. The include must be the first section.
    pkgs.writeText "ai-gitconfig-${runtime}" (
      lib.generators.toGitINI {
        include.path = userConfigs ++ lib.toList (body.include.path or []);
      }
      + lib.generators.toGitINI (removeAttrs body ["include"])
    );

  states = lib.genAttrs harnessNames (runtime: let
    gitCfg = resolveGit runtime;
    ghCfg = gh.resolve config runtime;
    enabled = runtimeEnabled runtime;
  in {
    inherit ghCfg gitCfg runtime;
    gitActive = enabled && gitCfg.enable;
    ghActive = enabled && ghCfg.enable;
    gitconfig = renderGitconfig runtime gitCfg;
  });

  envFor = runtime: let
    state = states.${runtime};
  in
    lib.optionalAttrs state.gitActive {GIT_CONFIG_GLOBAL = "${state.gitconfig}";}
    // lib.optionalAttrs (state.ghActive && state.ghCfg.configDir != null) {
      GH_CONFIG_DIR = state.ghCfg.configDir;
    };

  assertionsFor = state: let
    prefix = "ai.${state.runtime}.programs";
  in
    lib.optionals state.gitActive [
      {
        assertion = !state.gitCfg.signing.signByDefault || state.gitCfg.signing.key != null;
        message = "${prefix}.git.signing.signByDefault is on but no signing key resolves for ${state.runtime}. Set ai.programs.git.signing.key or ${prefix}.git.signing.key; commits would otherwise go out unsigned.";
      }
      {
        assertion = !state.gitCfg.signing.signByDefault || state.gitCfg.signing.format != null;
        message = "${prefix}.git.signing.signByDefault is on but no signing format resolves for ${state.runtime}. Set ai.programs.git.signing.format (\"ssh\", \"openpgp\" or \"x509\").";
      }
    ]
    ++ lib.optional state.ghActive {
      assertion = state.ghCfg.configDir != null;
      message = "${prefix}.gh.enable needs a config directory: set ai.programs.gh.configDir or ${prefix}.gh.configDir.";
    };
in {
  imports = [git.module gh.module];

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? assertions) {
      assertions = lib.concatMap assertionsFor (lib.attrValues states);
    })
    (moduleEnvironment.publish options envFor)
  ];
}
