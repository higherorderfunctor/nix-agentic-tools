{signers}: {
  lib,
  pkgs,
  ...
}: let
  signer = import ../lib/mkSshSigner.nix pkgs;
in {
  imports = [
    (import ../../ai-module/lib/runtime.nix {
      enabled = true;
      name = "microvm";
    })
  ];
  # ai.services owns key delivery and rotation; one agent belongs to each
  # routed runtime/identity, even when two identities reference the same key.
  config.ai.microvm.services = lib.mkMerge (lib.mapAttrsToList (_: identities:
    lib.mapAttrs' (_: entry: let
      command = import ../../../lib/strict-shell-application.nix pkgs {
        name = entry.service;
        text = ''
          exec ${lib.getExe signer} ${entry.runtimeDir}/agent.sock "$SIGNING_KEY"
        '';
      };
    in
      lib.nameValuePair entry.service {
        command = [(lib.getExe command)];
        environment.SIGNING_KEY = entry.key;
      })
    identities)
  signers);
}
