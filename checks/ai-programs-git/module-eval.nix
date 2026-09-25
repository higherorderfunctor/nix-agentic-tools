# `ai.programs.git` / `ai.programs.gh` — the per-harness git and gh identity
# (lib/ai/programs/git.nix). Both backends, every runtime from the registry.
# cspell:ignore insteadof
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames mkTest;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };

  # Light stand-ins, so a wrapper test builds a makeWrapper script rather than
  # a whole CLI. The real packages' wrapping is covered by their own checks.
  exes = {
    claude = "claude";
    codex = "codex";
    copilot = "copilot";
    kimchi = "kimchi";
    kiro = "kiro-cli";
  };
  stub = exe:
    pkgs.writeShellScriptBin exe ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exit 0
    '';
  launcherRuntimes = lib.remove "claude" harnessNames;

  tokenFile = "/run/secrets/ai-github-token";
  ghDir = "/run/ai-gh";
  keyFor = runtime: "/run/secrets/ai-${runtime}-signing-key";

  # The design's consumer shape: shared email, token and signing policy at the
  # root; each harness's own name and key at the runtime.
  identity = {
    ai =
      lib.genAttrs harnessNames (runtime: {
        enable = true;
        package = stub exes.${runtime};
        programs.git = {
          settings.user.name = "bot (${runtime})";
          signing.key = keyFor runtime;
        };
      })
      // {
        programs = {
          git = {
            enable = true;
            settings = {
              user.email = "bot@example.com";
              url."https://github.com/".insteadOf = ["git@github.com:" "ssh://git@github.com/"];
            };
            signing = {
              format = "ssh";
              signByDefault = true;
            };
            credentials.file = tokenFile;
          };
          gh = {
            enable = true;
            configDir = ghDir;
          };
        };
      };
  };

  channel = ev: runtime: ev.config.ai.${runtime}.internal._moduleEnvironmentVariables;
  claudeEnv = backend: ev:
    if backend == "hm"
    then ev.config.programs.claude-code.settings.env or {}
    else ev.config.files.".claude/settings.json".json.env or {};
  failedMessages = ev:
    map (entry: entry.message)
    (builtins.filter (entry: !entry.assertion) ev.config.assertions);
  ourFailures = ev: builtins.filter (lib.hasInfix ".programs.g") (failedMessages ev);

  # Every leaf under the two programs at both levels. Each program is a
  # submodule option, so descend through its type rather than the option.
  optionNames = ev: let
    programOptions =
      [ev.options.ai.programs.git ev.options.ai.programs.gh]
      ++ lib.concatMap (runtime: [
        ev.options.ai.${runtime}.programs.git
        ev.options.ai.${runtime}.programs.gh
      ])
      harnessNames;
    leaves = option: lib.collect lib.isOption (option.type.getSubOptions option.loc);
  in
    lib.sort lib.lessThan (map (option: lib.showOption option.loc) (lib.concatMap leaves programOptions));

  tokenKeys = ["GH_TOKEN" "GITHUB_TOKEN"];
in {
  checks = {
    # The declarations are one file imported by sharedOptions.nix on both
    # backends; this is what keeps it that way. The `elem` probes are the
    # positive control: an empty tree on both sides would compare equal.
    module-ai-programs-git-hm-devenv-option-parity = mkTest "ai-programs-git-hm-devenv-option-parity" (
      let
        hm = optionNames (evalHm {});
      in
        hm
        == optionNames (evalDevenv {})
        && builtins.all (name: builtins.elem name hm) [
          "ai.programs.git.credentials"
          "ai.programs.git.settings"
          "ai.programs.git.signing.format"
          "ai.programs.git.signing.key"
          "ai.programs.git.signing.signByDefault"
          "ai.programs.gh.configDir"
          "ai.claude.programs.git.signing.key"
          "ai.kimchi.programs.gh.configDir"
        ]
    );

    # Off by default, and never a write into the user's own git config: the
    # Home Manager `programs.git.settings` carries only the SSH workaround.
    module-ai-programs-git-inert-and-hands-off = mkTest "ai-programs-git-inert-and-hands-off" (
      let
        off = evalHm {ai.codex.enable = true;};
        on = evalHm identity;
      in
        !((channel off "codex") ? GIT_CONFIG_GLOBAL)
        && !((channel off "codex") ? GH_CONFIG_DIR)
        && builtins.attrNames on.config.programs.git.settings == ["core"]
        && builtins.attrNames on.config.programs.git.settings.core == ["sshCommand"]
    );

    # GIT_CONFIG_GLOBAL and GH_CONFIG_DIR reach every runtime on both backends,
    # the gitconfig differs per runtime (each has its own name and key), and no
    # token variable is emitted anywhere. Claude is checked at its real sink,
    # `settings.env`; the launcher runtimes by the wrapper test below.
    module-ai-programs-git-env-per-runtime = mkTest "ai-programs-git-env-per-runtime" (
      builtins.all (backend: let
        ev = backends.${backend} identity;
        configs = map (runtime: (channel ev runtime).GIT_CONFIG_GLOBAL or null) harnessNames;
        claude = claudeEnv backend ev;
      in
        builtins.all (value: value != null && lib.hasPrefix builtins.storeDir value) configs
        && lib.length (lib.unique configs) == lib.length harnessNames
        && builtins.all (runtime: (channel ev runtime).GH_CONFIG_DIR or null == ghDir) harnessNames
        && builtins.all (runtime: lib.hasSuffix "-ai-gitconfig-${runtime}" (channel ev runtime).GIT_CONFIG_GLOBAL) harnessNames
        && (claude.GIT_CONFIG_GLOBAL or null) == (channel ev "claude").GIT_CONFIG_GLOBAL
        && (claude.GH_CONFIG_DIR or null) == ghDir
        && builtins.all (key: !(claude ? ${key})) tokenKeys
        && builtins.all (runtime: builtins.all (key: !((channel ev runtime) ? ${key})) tokenKeys) harnessNames
        && ourFailures ev == [])
      (builtins.attrNames backends)
    );

    # A runtime can opt out, and a consumer's explicit entry still wins over
    # the module default (the channel's existing contract).
    module-ai-programs-git-runtime-opt-out-and-consumer-wins = mkTest "ai-programs-git-runtime-opt-out-and-consumer-wins" (
      builtins.all (backend: let
        ev = backends.${backend} (lib.recursiveUpdate identity {
          ai = {
            codex.programs.git.enable = false;
            claude.native.settings.env.GIT_CONFIG_GLOBAL = "/explicit/gitconfig";
          };
        });
      in
        !((channel ev "codex") ? GIT_CONFIG_GLOBAL)
        && (channel ev "codex").GH_CONFIG_DIR == ghDir
        && (claudeEnv backend ev).GIT_CONFIG_GLOBAL == "/explicit/gitconfig")
      (builtins.attrNames backends)
    );

    # A key under the store is world-readable; the type refuses it at either
    # level. The /run value is the positive control: the same probe must
    # succeed when only the path changes.
    module-ai-programs-git-store-signing-key-rejected = mkTest "ai-programs-git-store-signing-key-rejected" (
      let
        # Force BOTH levels: a store key at either one must throw.
        probe = settings: let
          inherit ((evalHm settings).config.ai) programs claude;
        in
          (builtins.tryEval (builtins.deepSeq [
              programs.git.signing.key
              claude.programs.git.signing.key
            ]
            true)).success;
        storeKey = "${builtins.storeDir}/00000000000000000000000000000000-key";
      in
        !(probe {ai.programs.git.signing.key = storeKey;})
        && !(probe {ai.claude.programs.git.signing.key = storeKey;})
        && probe {ai.programs.git.signing.key = "/run/secrets/key";}
        && probe {ai.claude.programs.git.signing.key = "/run/secrets/key";}
    );

    # signByDefault with nothing to sign with is an eval error (assertion), not
    # a silent unsigned commit. Only enabled runtimes are held to it, and the
    # full identity is the positive control.
    module-ai-programs-git-sign-by-default-needs-key-and-format = mkTest "ai-programs-git-sign-by-default-needs-key-and-format" (
      builtins.all (backend: let
        eval = backends.${backend};
        noKey = eval (lib.recursiveUpdate identity {ai.kiro.programs.git.signing.key = null;});
        noFormat = eval (lib.recursiveUpdate identity {ai.programs.git.signing.format = null;});
        noGhDir = eval (lib.recursiveUpdate identity {ai.programs.gh.configDir = null;});
        disabledRuntime = eval (lib.recursiveUpdate identity {
          ai.kiro = {
            enable = false;
            programs.git.signing.key = null;
          };
        });
      in
        builtins.any (lib.hasPrefix "ai.kiro.programs.git.signing.signByDefault is on but no signing key") (ourFailures noKey)
        && lib.length (ourFailures noKey) == 1
        && builtins.any (lib.hasPrefix "ai.claude.programs.git.signing.signByDefault is on but no signing format") (ourFailures noFormat)
        && lib.length (ourFailures noFormat) == lib.length harnessNames
        && builtins.any (lib.hasPrefix "ai.codex.programs.gh.enable needs a config directory") (ourFailures noGhDir)
        && ourFailures disabledRuntime == []
        && ourFailures (eval identity) == [])
      (builtins.attrNames backends)
    );

    # The rendered file, read by real git. Checks the four things the design
    # rests on: `[include]` is the FIRST section; the per-runtime `user.name`
    # deep-merges with the root `user.email`; the credential reset comes AFTER
    # the user's included helper, so git keeps only the agent's; signing pins
    # the store ssh-keygen. The fake HOME's gitconfig stands in for the user's.
    module-ai-programs-git-rendered-gitconfig = let
      ev = evalHm identity;
      file = runtime: (channel ev runtime).GIT_CONFIG_GLOBAL;
      userGitconfig = pkgs.writeText "user-gitconfig" ''
        [user]
          name = the-operator
          email = operator@example.com
        [credential "https://github.com"]
          helper = operator-helper
        [commit]
          gpgSign = false
      '';
    in
      pkgs.runCommand "module-test-ai-programs-git-rendered-gitconfig" {nativeBuildInputs = [pkgs.git];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "FAIL: ai-programs-git-rendered-gitconfig: $1" >&2
          exit 1
        }
        # `--global` alone reads ONE file and skips its includes (git's rule
        # for any specific file), which would hide exactly what is tested.
        cfg() {
          git config --includes --global "$@"
        }
        export HOME="$PWD/home"
        mkdir -p "$HOME"
        cp ${userGitconfig} "$HOME/.gitconfig"

        ${lib.concatMapStringsSep "\n" (runtime: ''
            export GIT_CONFIG_GLOBAL=${file runtime}
            [ "$(head -n1 "$GIT_CONFIG_GLOBAL")" = '[include]' ] || fail "${runtime}: first section is not [include]"
            [ "$(cfg user.name)" = 'bot (${runtime})' ] || fail "${runtime}: user.name"
            [ "$(cfg user.email)" = 'bot@example.com' ] || fail "${runtime}: root user.email lost by the runtime override"
            [ "$(cfg user.signingKey)" = '${keyFor runtime}' ] || fail "${runtime}: user.signingKey"
            [ "$(cfg commit.gpgSign)" = true ] || fail "${runtime}: commit.gpgSign"
            [ "$(cfg tag.gpgSign)" = true ] || fail "${runtime}: tag.gpgSign"
            [ "$(cfg gpg.format)" = ssh ] || fail "${runtime}: gpg.format"
            [ "$(cfg gpg.ssh.program)" = '${lib.getExe' pkgs.openssh "ssh-keygen"}' ] || fail "${runtime}: gpg.ssh.program"
            cfg --get-all url.https://github.com/.insteadOf > insteadof
            printf '%s\n' 'git@github.com:' 'ssh://git@github.com/' | cmp -s - insteadof || fail "${runtime}: insteadOf"
            # operator-helper, then the reset, then the agent's helper: git
            # drops everything before the empty value.
            cfg --get-all credential.https://github.com.helper > helpers
            [ "$(wc -l < helpers)" -eq 3 ] || fail "${runtime}: expected three helper entries"
            [ "$(sed -n 1p helpers)" = operator-helper ] || fail "${runtime}: include is not first"
            [ -z "$(sed -n 2p helpers)" ] || fail "${runtime}: reset does not follow the include"
            helper="$(sed -n 3p helpers)"
            case "$helper" in
              ${builtins.storeDir}/*/bin/ai-git-credential-github) ;;
              *) fail "${runtime}: agent helper is $helper" ;;
            esac
            grep -Fq '${tokenFile}' "$helper" || fail "${runtime}: helper does not read the token file"
            if grep -Eq 'GH_TOKEN|GITHUB_TOKEN' "$GIT_CONFIG_GLOBAL" "$helper"; then
              fail "${runtime}: token variable emitted"
            fi
            [ -z "$("$helper" store </dev/null)" ] || fail "${runtime}: helper answered a store request"
          '')
          harnessNames}
        echo "PASS: ai-programs-git-rendered-gitconfig" > "$out"
      '';

    # The launcher runtimes carry their own gitconfig and the gh dir in the
    # wrapper they install, on both backends, and no token variable.
    module-ai-programs-git-launchers-carry-env = let
      wrappers = lib.concatMap (backend: let
        ev = backends.${backend} identity;
        installed =
          if backend == "hm"
          then ev.config.home.packages
          else ev.config.packages;
      in
        map (runtime: {
          inherit backend runtime;
          bin = exes.${runtime};
          packages = installed;
          gitconfig = (channel ev runtime).GIT_CONFIG_GLOBAL;
        })
        launcherRuntimes) (builtins.attrNames backends);
    in
      pkgs.runCommand "module-test-ai-programs-git-launchers-carry-env" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "FAIL: ai-programs-git-launchers-carry-env: $1" >&2
          exit 1
        }
        ${lib.concatMapStringsSep "\n" (wrapper: ''
            found=
            for pkg in ${lib.concatMapStringsSep " " toString wrapper.packages}; do
              if [ -e "$pkg/bin/${wrapper.bin}" ]; then
                found="$pkg/bin/${wrapper.bin}"
              fi
            done
            [ -n "$found" ] || fail "${wrapper.backend}/${wrapper.runtime}: no installed ${wrapper.bin}"
            ${pkgs.gnugrep}/bin/grep -Fq GIT_CONFIG_GLOBAL "$found" || fail "${wrapper.backend}/${wrapper.runtime}: GIT_CONFIG_GLOBAL missing"
            ${pkgs.gnugrep}/bin/grep -Fq '${wrapper.gitconfig}' "$found" || fail "${wrapper.backend}/${wrapper.runtime}: its own gitconfig missing"
            ${pkgs.gnugrep}/bin/grep -Fq '${ghDir}' "$found" || fail "${wrapper.backend}/${wrapper.runtime}: GH_CONFIG_DIR missing"
            if ${pkgs.gnugrep}/bin/grep -Eq 'GH_TOKEN|GITHUB_TOKEN' "$found"; then
              fail "${wrapper.backend}/${wrapper.runtime}: token variable emitted"
            fi
          '')
          wrappers}
        echo "PASS: ai-programs-git-launchers-carry-env" > "$out"
      '';
  };
}
