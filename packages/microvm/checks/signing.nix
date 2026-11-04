# cspell:ignore guestfwd
{
  harness,
  lib,
  pkgs,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  backends = {
    devenv = harness.evalDevenv;
    hm = config: harness.evalHmModules [{inherit config;} {ai.codex.pinDaemonToPackage = false;}];
  };
  identity = token: {
    push.key = redact.file "/tmp/sandbox-push-fixture";
    remotes.${token}.forge = "github.com";
    user = {
      email = "signer@example.invalid";
      name = "Signing Fixture";
    };
  };
  fixture.ai = {
    claude = {
      enable = true;
      package = pkgs.hello;
    };
    codex = {
      enable = true;
      package = pkgs.hello;
    };
    sandbox = {
      enable = true;
      git.identities = {
        signed = (identity "signed") // {signing.key = redact.file "/tmp/sandbox-signing-fixture";};
        unsigned = identity "unsigned";
      };
    };
  };
  signerNames = config: builtins.filter (lib.hasPrefix "sandbox-signer-") (builtins.attrNames config.ai.services);
  check = name: test:
    lib.mapAttrs' (backend: eval:
      lib.nameValuePair "microvm-signing-${name}-${backend}" (harness.mkTest "microvm-signing-${name}-${backend}" (test backend eval)))
    backends;
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
    check "services" (backend: eval: let
      result = (eval fixture).config;
      service = result.ai.services.sandbox-signer-codex-signed;
      package = lib.findFirst (p: p.meta.mainProgram == "codex-sandbox") (throw "missing launcher") result.ai.internal.sandboxPackages;
      signedGuest = package.signed.guest.config;
      unsignedGuest = package.connected.guest.config;
      forwards = guest: lib.findFirst (lib.hasPrefix "user,id=doors") "" guest.microvm.qemu.extraArgs;
    in
      signerNames result
      == ["sandbox-signer-claude-signed" "sandbox-signer-codex-signed"]
      && redact.isAsFile service.environment.SIGNING_KEY
      && services.triggers service == ["/tmp/sandbox-signing-fixture"]
      && result.ai.claims.service.sandbox-signer-codex-signed == ["microvm"]
      && (
        if backend == "hm"
        then result.systemd.user.services ? sandbox-signer-codex-signed
        else result.processes ? sandbox-signer-codex-signed
      )
      && builtins.elem pkgs.openssh signedGuest.environment.systemPackages
      && lib.hasInfix "guestfwd=tcp:10.0.2.100:2222-cmd:" (forwards signedGuest)
      && !lib.hasInfix ":2222-cmd:" (forwards unsignedGuest)
      && signedGuest.systemd.services.sandbox.serviceConfig.Environment == ["SSH_AUTH_SOCK=/run/sandbox-signing/agent.sock"]
      && lib.hasInfix "UNIX-LISTEN:/run/sandbox-signing/agent.sock,fork,mode=0600" signedGuest.systemd.services.sandbox-signing-agent.serviceConfig.ExecStart
      && unsignedGuest.systemd.services.sandbox.serviceConfig.Environment == []
      && builtins.elem "name=opt/sandbox.allowed-signers,file=allowed-signers" signedGuest.microvm.qemu.extraArgs)
    // check "email" (_: eval: let
      refused = identity: email:
        lib.any (assertion:
          !assertion.assertion && lib.hasInfix "allowed-signers principal" assertion.message)
        (eval (lib.recursiveUpdate fixture {ai.sandbox.git.identities.${identity}.user.email = email;})).config.assertions;
    in
      lib.all (refused "signed") ["" "#bot@example.invalid" "two names@example.invalid" "a@b,b@c" "a\nb" "*" "*@example.invalid" "bot?@example.invalid" "!bot@example.invalid"]
      && !refused "signed" "bot+signing@example.invalid"
      && !refused "unsigned" "two names@example.invalid")
    // check "empty" (_: eval:
      signerNames (eval {}).config
      == []
      && signerNames (eval (lib.recursiveUpdate fixture {ai.sandbox.git.identities.signed.signing.key = null;})).config == []
      && signerNames (eval (lib.recursiveUpdate fixture {ai.sandbox.enable = false;})).config == []
      && signerNames (eval (lib.recursiveUpdate fixture {ai.codex.sandbox.enable = false;})).config == ["sandbox-signer-claude-signed"]
      && signerNames
      (eval (lib.recursiveUpdate fixture {
        ai = {
          claude.enable = false;
          codex.enable = false;
          kiro.cli.enable = true;
        };
      })).config
      == [])
    // check "plaintext" (_: eval:
      !succeeds (eval (lib.recursiveUpdate fixture {ai.sandbox.git.identities.signed.signing.key = "plaintext-test-key";})).config.ai.sandbox.git.identities.signed.signing.key)
  );
}
