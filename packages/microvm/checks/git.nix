# cspell:ignore extraheader maxstack signingkey sshcommand
# Evaluation contracts of the sandbox's Git surface (modules/git.nix): the
# copy-down priority matrix (raw and typed keys into the runtime `_ini` sink),
# enable propagation into the guest package list, the owner's
# test.jobs/test.strategy coupling holding across the root-to-runtime typed
# copy-down, credential-carrying keys refused, and the rendered system
# configuration (the guest-fixed keys after the consumer's) parsing with real
# git. The host tool instantiations stay byte-identical through their own
# checks (checks/git-config/module-eval.nix).
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
  # A guest-side probe: exits non-zero when the guest disagrees. Needs KVM, so
  # it rides a launcher to run by hand, not a sandboxed build.
  mkGuestScript = name: text:
    import ../../../lib/strict-shell-application.nix pkgs {
      inherit name text;
      runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.git];
    };
  # One matrix row per backend: the sink is backend-independent, but the
  # surrounding module set differs.
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  forBackends = name: test:
    lib.mapAttrs' (backend: eval:
      lib.nameValuePair "microvm-git-${name}-${backend}" (mkTest "microvm-git-${name}-${backend}" (test eval)))
    backends;
  # The merged sink of one runtime (codex carries each row's runtime side).
  sink = eval: config: (eval config).config.ai.codex.sandbox.git._ini;
  # The rendered system configuration of the same runtime.
  rendered = eval: config: (eval config).config.ai.codex.sandbox.git._config;
  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  failedMessages = eval: config:
    map (a: a.message) (lib.filter (a: !a.assertion) (eval config).config.assertions);
  rootRaw = {ai.sandbox.git.settings.absorb.maxStack = 20;};
  runtimeTypedLeaf = {ai.codex.sandbox.git.absorb.settings.maxStack = 30;};
  hostSettings = config: (evalHm config).config.programs.git.settings;
  renderFixture = lib.recursiveUpdate rootRaw {ai.codex.sandbox.git.revise.settings.rerere = true;};
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    (forBackends "copy-down" (eval: let
      empty = sink eval {};
      rawOnly = sink eval rootRaw;
      rawPlusTyped = sink eval renderFixture;
    in
      # Nothing set: no consumer keys, in every runtime.
      empty
      == {}
      && lib.all (runtime: (eval {}).config.ai.${runtime}.sandbox.git._ini == empty) ["claude" "codex"]
      # Root raw only: every runtime's guest gets it.
      && rawOnly.absorb.maxStack == 20
      # Root raw plus a runtime typed leaf: the raw keys are kept.
      && rawPlusTyped
      == {
        absorb.maxStack = 20;
        revise.rerere = true;
      }
      # Host tool instantiations are unchanged beside the sandbox tree.
      && hostSettings {git.absorb.settings.maxStack = 3;} == {absorb.maxStack = 3;}))
    // (forBackends "priority" (eval:
      # A nested mkDefault root key loses to the runtime's typed value for
      # that key, without a conflict.
        (sink eval (lib.recursiveUpdate {ai.sandbox.git.settings.absorb.maxStack = lib.mkDefault 20;} runtimeTypedLeaf)).absorb.maxStack
        == 30
        # A runtime `settings` definition replaces the root's whole value: the
        # root's other keys are gone.
        && (let
          replaced = sink eval (lib.recursiveUpdate rootRaw {ai.codex.sandbox.git.settings.core.editor = "vim";});
        in
          replaced.core.editor == "vim" && !(replaced ? absorb))
        # Equal-priority raw/typed disagreement stays a loud conflict, root raw
        # vs runtime typed.
        && !(evaluates (sink eval (lib.recursiveUpdate rootRaw runtimeTypedLeaf)))
        # A root typed leaf forwards as a weak default: a raw key at normal
        # priority beats it without a conflict.
        && (sink eval (lib.recursiveUpdate rootRaw {ai.sandbox.git.absorb.settings.maxStack = 30;})).absorb.maxStack == 20
        # A runtime typed leaf replaces the root's value for the same leaf,
        # even as a mkDefault, and leaves the other runtime on the root's.
        && (let
          shared = {ai.sandbox.git.absorb.settings.maxStack = 10;};
          replaced = lib.recursiveUpdate shared runtimeTypedLeaf;
          defaulted = lib.recursiveUpdate shared {ai.codex.sandbox.git.absorb.settings.maxStack = lib.mkDefault 30;};
        in
          (sink eval replaced).absorb.maxStack
          == 30
          && (sink eval defaulted).absorb.maxStack == 30
          && (eval replaced).config.ai.claude.sandbox.git._ini.absorb.maxStack == 10)))
    // (forBackends "fixed-keys" (eval: let
      # Values for the guest-fixed keys, in the spellings Git folds into one.
      consumer = {
        ai.codex.sandbox.git.settings = {
          Core.SSHCommand = "ssh-upper";
          core.sshCommand = "ssh";
          core.sshcommand = "ssh-lower";
          safe.directory = ["/evil"];
        };
      };
      text = rendered eval consumer;
    in
      # The consumer's keys stay in the file, ahead of the fixed ones...
      lib.hasInfix "sshcommand = \"ssh-lower\"" text
      && lib.hasInfix "SSHCommand = \"ssh-upper\"" text
      && lib.hasInfix "directory = \"/evil\"" text
      # ...which close it: Git takes the last value, and the empty
      # `safe.directory` resets the consumer's list before the seed path.
      && lib.hasInfix "[core]\n\tsshCommand = \"/nix/store/" text
      && lib.hasSuffix "/bin/sandbox-no-ssh\"\n\n[safe]\n\tdirectory = \"\"\n\tdirectory = \"/mnt/seed\"\n" text
      # Nothing set: the fixed keys alone.
      && lib.hasPrefix "[core]\n\tsshCommand = \"/nix/store/" (rendered eval {})))
    // (forBackends "refusals" (eval: let
      # Each row: the settings, then the key the message must name. The file
      # is world-readable in the store, so a credential, or a key that can
      # pull one in, fails evaluation in whichever tree defines it.
      refused = path: settings: key:
        lib.any (lib.hasPrefix "${path}.settings sets ${key}, which the sandbox guest's git configuration refuses.") (failedMessages eval (lib.setAttrByPath (lib.splitString "." path) {inherit settings;}));
      codex = "ai.codex.sandbox.git";
      root = "ai.sandbox.git";
    in
      refused codex {credential.helper = "store --file /home/user/.git-credentials";} "credential.helper"
      && refused codex {"credential.https://example.com".username = "user";} "credential.https://example.com.username"
      && refused codex {Credential.Helper = "store";} "Credential.Helper"
      && refused codex {http."https://example.com/".extraHeader = "Authorization: Bearer token";} "http.https://example.com/.extraHeader"
      && refused codex {"http.https://example.com/".extraheader = "Authorization: Bearer token";} "http.https://example.com/.extraheader"
      && refused codex {HTTP.ExtraHeader = "Authorization: Bearer token";} "HTTP.ExtraHeader"
      && refused codex {user.signingKey = "/home/user/.ssh/id_ed25519";} "user.signingKey"
      && refused codex {user.SIGNINGKEY = "/home/user/.ssh/id_ed25519";} "user.SIGNINGKEY"
      && refused codex {gpg.ssh.program = "/home/user/bin/signer";} "gpg.ssh.program"
      && refused codex {url."https://token@example.com/".insteadOf = "https://example.com/";} "url.https://token@example.com/.insteadOf"
      && refused codex {url."https://token@example.com/".pushInsteadOf = "https://example.com/";} "url.https://token@example.com/.pushInsteadOf"
      && refused codex {include.path = "/home/user/.gitconfig";} "include.path"
      && refused codex {includeIf."gitdir:/home/user/".path = "/home/user/.gitconfig";} "includeIf.gitdir:/home/user/.path"
      # The shared root is checked once, under its own path.
      && refused root {credential.helper = "store";} "credential.helper"
      && !(lib.any (lib.hasPrefix "ai.codex.sandbox.git.settings sets") (failedMessages eval {ai.sandbox.git.settings.credential.helper = "store";}))
      # Ordinary host settings pass, including keys that only sit near a
      # refused one.
      && failedMessages eval {
        ai.sandbox.git.settings = {
          core.editor = "nano";
          http.postBuffer = 524288000;
          url."https://example.com/".someOtherKey = "x";
          user.name = "Sandbox";
        };
        ai.codex.sandbox.git.settings.core.sshcommand = "ssh";
      }
      == []))
    // (forBackends "enable" (eval: let
      absorbPackage = (eval {ai.sandbox.git.absorb.enable = true;}).config.ai.internal.packages.gitTools.git-absorb;
      packages = config: (eval config).config.ai.codex.sandbox.git._packages;
    in
      # Root enable defaults every runtime's tree on; runtime enable replaces
      # it at any priority, in either direction.
      packages {ai.sandbox.git.absorb.enable = true;}
      == [absorbPackage]
      && packages {ai.codex.sandbox.git.absorb.enable = true;} == [absorbPackage]
      && packages {
        ai.sandbox.git.absorb.enable = true;
        ai.codex.sandbox.git.absorb.enable = false;
      }
      == []
      && packages {} == []
      # The owner's per-tool assertion travels with the factory, mounted root
      # in the message.
      && lib.any (lib.hasInfix "ai.sandbox.git.branchless.settings.test.jobs = 4 contradicts") (
        failedMessages eval {
          ai.sandbox.git.branchless.settings.test = {
            jobs = 4;
            strategy = "working-copy";
          };
        }
      )))
    // (forBackends "coupling" (eval: let
      # A root `test.jobs` a runtime `test.strategy` has to meet inside the
      # runtime's typed tree: the inherited leaf forwards into it, so the
      # owner's assertions read both together, and the system file being the
      # guest's lowest Git scope makes an unset strategy upstream's
      # working-copy, which a jobs value above 1 cannot run with.
      both = {
        ai.sandbox.git.branchless.settings.test.jobs = 4;
        ai.codex.sandbox.git.branchless.settings.test.strategy = "working-copy";
      };
      rootOnly = {ai.sandbox.git.branchless.settings.test.jobs = 4;};
      ini = config: (sink eval config).branchless.test;
      needsWorktree = lib.hasInfix ''ai.codex.sandbox.git.branchless.settings.test.jobs = 4 needs ai.codex.sandbox.git.branchless.settings.test.strategy = "worktree"'';
    in
      # The root's jobs reaches the runtime tree its strategy lands in: the
      # shared contradiction fires there, and both values render.
      lib.any (lib.hasInfix ''ai.codex.sandbox.git.branchless.settings.test.jobs = 4 contradicts ai.codex.sandbox.git.branchless.settings.test.strategy = "working-copy"'') (failedMessages eval both)
      && ini both
      == {
        jobs = 4;
        strategy = "working-copy";
      }
      # An unset strategy fails from the root's forwarded leaf and from the
      # runtime's own alike, and writes no key.
      && lib.any needsWorktree (failedMessages eval rootOnly)
      && lib.any needsWorktree (failedMessages eval {ai.codex.sandbox.git.branchless.settings.test.jobs = 4;})
      && ini rootOnly == {jobs = 4;}))
    // {
      # The module-built launcher's guest carries the rendered configuration
      # as its SYSTEM git file and the enabled tool's package in its system
      # profile.
      microvm-git-guest = let
        fixture.ai = {
          claude = {
            enable = true;
            package = pkgs.hello;
          };
          sandbox = {
            enable = true;
            git.absorb.enable = true;
          };
        };
        result = evalHm fixture;
        launcher = lib.findFirst (package: package.meta.mainProgram == "claude-sandbox") (throw "missing claude-sandbox") result.config.ai.internal.sandboxPackages;
      in
        mkTest "microvm-git-guest" (
          lib.hasInfix "/bin/sandbox-no-ssh" launcher.guest.config.environment.etc.gitconfig.text
          && lib.hasInfix "/mnt/seed" launcher.guest.config.environment.etc.gitconfig.text
          && builtins.elem result.config.ai.internal.packages.gitTools.git-absorb launcher.guest.config.environment.systemPackages
        );
      # A standalone repo guest that passes its own configuration keeps the
      # seed trust the clone needs.
      microvm-git-repo-guest = let
        text =
          (self.lib.ai.mkSandbox pkgs {
            exe = lib.getExe pkgs.hello;
            gitConfig = lib.generators.toGitINI {core.editor = "nano";};
            outName = "sandbox-git-repo";
            repo = true;
          }).guest.config.environment.etc.gitconfig.text;
      in
        mkTest "microvm-git-repo-guest" (
          lib.hasInfix ''editor = "nano"'' text && lib.hasInfix "directory = /mnt/seed" text
        );
      # Hand-run under KVM, like the other sandbox smoke launchers: the
      # module-built guest runs this probe, proving the rendered system
      # configuration is live — the forced core.sshCommand refuses and names
      # origin, and the seed safe.directory entry is set.
      microvm-git-launcher = let
        probe = mkGuestScript "sandbox-git-probe" ''
          ssh_command="$(git config --system core.sshCommand)"
          [[ $ssh_command == */bin/sandbox-no-ssh ]]
          if "$ssh_command" > /dev/null 2> ssh.refusal; then
            echo 'SANDBOX_GIT_SSH_ALLOWED' >&2
            exit 1
          fi
          grep -q 'Push through' ssh.refusal
          # The empty value resets the list; the seed path follows it.
          [[ $(git config --system --get-all safe.directory | sort | paste -sd:) == :/mnt/seed ]]
          echo SANDBOX_GIT_OK
        '';
        result = evalHm {
          ai.claude = {
            enable = true;
            package = probe;
          };
          ai.sandbox.enable = true;
        };
      in
        lib.findFirst (package: package.meta.mainProgram == "claude-sandbox") (throw "missing claude-sandbox") result.config.ai.internal.sandboxPackages;
      # The rendered system configuration parses with real git: the consumer's
      # raw keys and typed leaf are in it, and the guest-fixed keys come last,
      # so every case spelling of a consumer value for them loses.
      microvm-git-render = let
        text = rendered evalDevenv (lib.recursiveUpdate renderFixture {
          ai.sandbox.git.settings = {
            Core.SSHCommand = "ssh-upper";
            core.sshCommand = "ssh";
            core.sshcommand = "ssh-lower";
            Safe.Directory = ["/evil-upper"];
            safe.directory = ["/evil"];
          };
        });
      in
        mkLintedCheck "microvm-git-render" {
          runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.git];
          text = ''
            config_file="$(mktemp)"
            trap 'rm -f -- "$config_file"' EXIT
            printf '%s' ${lib.escapeShellArg (builtins.unsafeDiscardStringContext text)} > "$config_file"
            git config --file "$config_file" --list > "$out.listed"
            grep -Exq 'absorb\.maxstack=20' "$out.listed"
            grep -Exq 'revise\.rerere=true' "$out.listed"
            # Every consumer spelling is still in the file, ahead of the fixed key.
            [[ $(grep -Ec '^core\.sshcommand=' "$out.listed") == 4 ]]
            [[ $(grep -E '^core\.sshcommand=' "$out.listed" | tail -n 1) == core.sshcommand=/nix/store/*/bin/sandbox-no-ssh ]]
            [[ $(git config --file "$config_file" core.sshCommand) == /nix/store/*/bin/sandbox-no-ssh ]]
            # The fixed safe.directory resets the consumer's list, then adds the seed.
            [[ $(grep -c '^safe\.directory=' "$out.listed") == 4 ]]
            [[ $(grep '^safe\.directory=' "$out.listed" | tail -n 2 | paste -sd,) == 'safe.directory=,safe.directory=/mnt/seed' ]]
          '';
        };
    }
  );
}
