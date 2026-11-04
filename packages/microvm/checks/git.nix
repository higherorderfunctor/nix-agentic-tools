# cspell:ignore maxstack sshcommand
# Evaluation contracts of the sandbox's Git surface (modules/git.nix): the
# copy-down priority matrix (raw, typed and fixed keys into the runtime `_ini`
# sink), enable propagation into the guest package list, and the rendered
# system configuration parsing with real git. The host tool instantiations
# stay byte-identical through their own checks (checks/git-config/module-eval.nix).
{
  harness,
  lib,
  pkgs,
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
      # Nothing set: the guest-fixed keys alone, in every runtime.
      removeAttrs empty ["core" "safe"]
      == {}
      && lib.hasInfix "/sandbox-no-ssh" empty.core.sshCommand
      && empty.safe.directory == ["/mnt/seed"]
      && lib.all (runtime: (eval {}).config.ai.${runtime}.sandbox.git._ini == empty) ["claude" "codex"]
      # Root raw only: every runtime's guest gets it under the fixed keys.
      && rawOnly.absorb.maxStack == 20
      # Root raw plus a runtime typed leaf: the raw keys are kept.
      && removeAttrs rawPlusTyped ["core" "safe"]
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
        # vs runtime typed and root raw vs root typed alike — as on the host.
        && !(evaluates (sink eval (lib.recursiveUpdate rootRaw runtimeTypedLeaf)))
        && !(evaluates (sink eval (lib.recursiveUpdate rootRaw {ai.sandbox.git.absorb.settings.maxStack = 30;})))
        # The guest-fixed keys win over a consumer's values, wholly.
        && (let
          forced = sink eval {
            ai.codex.sandbox.git.settings = {
              core.sshCommand = "ssh";
              safe.directory = ["/evil"];
            };
          };
        in
          lib.hasInfix "/sandbox-no-ssh" forced.core.sshCommand
          && forced.safe.directory == ["/mnt/seed"])))
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
          launcher.guest.config.environment.etc.gitconfig.text
          == lib.generators.toGitINI result.config.ai.claude.sandbox.git._ini
          && lib.hasInfix "/bin/sandbox-no-ssh" launcher.guest.config.environment.etc.gitconfig.text
          && builtins.elem result.config.ai.internal.packages.gitTools.git-absorb launcher.guest.config.environment.systemPackages
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
          [[ $(git config --system --get-all safe.directory | sort | paste -sd:) == /mnt/seed ]]
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
      # The rendered system configuration parses with real git and carries the
      # fixed keys, the raw keys and the typed leaf.
      microvm-git-render = let
        rendered = lib.generators.toGitINI (sink evalDevenv renderFixture);
      in
        mkLintedCheck "microvm-git-render" {
          runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.git];
          text = ''
            config_file="$(mktemp)"
            trap 'rm -f -- "$config_file"' EXIT
            printf '%s\n' ${lib.escapeShellArg (builtins.unsafeDiscardStringContext rendered)} > "$config_file"
            git config --file "$config_file" --list > "$out.listed"
            grep -Exq 'core\.sshcommand=/nix/store/[^/]+/bin/sandbox-no-ssh' "$out.listed"
            [[ $(grep -Exc -e 'safe\.directory=/mnt/seed' "$out.listed") == 1 ]]
            grep -Exq 'absorb\.maxstack=20' "$out.listed"
            grep -Exq 'revise\.rerere=true' "$out.listed"
          '';
        };
    }
  );
}
