{pkgs}: let
  inherit (pkgs) lib;
  certificateBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  strictScript = import ../strict-shell-application.nix pkgs;
in {
  mkSnapshot = {
    contentHash,
    generated ? {},
    hash,
    index ? null,
    meta,
    name,
    pin,
    snapshotDate,
    sources ? [],
    validate ? "",
  }: let
    # A source's `normalize` filters its fetched bytes (stdin to stdout)
    # before hashing, for an endpoint that stamps volatile fields per request.
    normalizeSource = source:
      source
      // lib.optionalAttrs (source ? normalize) {
        normalize = lib.getExe (strictScript {
          name = "${name}-normalize-${lib.strings.sanitizeDerivationName source.path}";
          text = source.normalize;
        });
      };
    config = pkgs.writeText "${name}-snapshot.json" (builtins.toJSON (
      {inherit contentHash generated name;}
      // (
        if index == null
        then {sources = map normalizeSource sources;}
        else {inherit index;}
      )
      // lib.optionalAttrs (validate != "") {
        validate = lib.getExe (strictScript {
          name = "${name}-validate";
          text = validate;
        });
      }
    ));
    runner = strictScript {
      name = "fetch-${name}";
      text = ''
        if [[ -n "''${NIX_SSL_CERT_FILE:-}" && -r "$NIX_SSL_CERT_FILE" ]]; then
          export SSL_CERT_FILE="$NIX_SSL_CERT_FILE"
        elif [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
          export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
        else
          export SSL_CERT_FILE=${certificateBundle}
        fi
        # Nixpkgs OpenSSL prefers this variable over SSL_CERT_FILE, including
        # stdenv's unreadable /no-cert-file.crt sentinel.
        export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
        exec ${pkgs.python3}/bin/python3 ${./snapshot.py} "$1" ${config} "''${@:2}"
      '';
    };
    updater = strictScript {
      name = "update-${name}";
      text = ''
        exec ${lib.getExe runner} update ${lib.escapeShellArg pin} ${pkgs.nix}/bin/nix
      '';
    };
  in
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      version = snapshotDate;
      NIX_SSL_CERT_FILE = certificateBundle;
      SSL_CERT_FILE = certificateBundle;
      phases = ["buildPhase"];
      buildPhase = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.getExe runner} snapshot "$out" ${lib.escapeShellArg snapshotDate}
      '';
      outputHash = hash;
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
      impureEnvVars = lib.fetchers.proxyImpureEnvVars;
      passthru = {
        snapshotConfig = config;
        updateScript = lib.getExe updater;
      };
      inherit meta;
    };
}
