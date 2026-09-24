{
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;

  snapshotDate = "2026-09-21";
  contentHash = "sha256-7Fek5Fs99f0WXl2CjLtVmhOl0UBlZoocEWAlcYods5k=";
  hash = "sha256-AS1Lxia1LOB/LpTV4sFe2siLWBziZURQSOeMStQtWHY=";
  recipe = repoPath ./package.nix;

  fetchDocs = pkgs.writeShellApplication {
    name = "fetch-kimchi-docs";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    runtimeInputs = [pkgs.python3];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      if [[ -n "''${NIX_SSL_CERT_FILE:-}" && -r "$NIX_SSL_CERT_FILE" ]]; then
        export SSL_CERT_FILE="$NIX_SSL_CERT_FILE"
      elif [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      else
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      fi
      exec python3 ${./fetch-docs.py} "$@"
    '';
  };

  updateScript = pkgs.writeShellApplication {
    name = "update-kimchi-docs";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    runtimeInputs = [fetchDocs pkgs.coreutils pkgs.nix pkgs.python3];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      work="$(mktemp -d)"
      cleanup() {
        chmod -R u+w "$work" 2>/dev/null || :
        rm -r -- "$work"
      }
      trap cleanup EXIT
      next_date="$(date -u +%F)"

      fetch-kimchi-docs "$work/snapshot" "$next_date" "$work/content-hash"
      read -r next_content_hash < "$work/content-hash"
      if [[ "$next_content_hash" == ${lib.escapeShellArg contentHash} ]]; then
        echo "kimchi-docs: documentation is unchanged"
        exit 0
      fi
      next_hash="$(nix hash path --type sha256 "$work/snapshot")"

      python3 - ${lib.escapeShellArg recipe} \
        ${lib.escapeShellArg snapshotDate} "$next_date" \
        ${lib.escapeShellArg contentHash} "$next_content_hash" \
        ${lib.escapeShellArg hash} "$next_hash" <<'PY'
      import pathlib
      import sys

      recipe_path = pathlib.Path(sys.argv[1])
      old_date, new_date, old_content_hash, new_content_hash, old_hash, new_hash = sys.argv[2:]
      text = recipe_path.read_text(encoding="utf-8")

      replacements = {
          f'snapshotDate = "{old_date}";': f'snapshotDate = "{new_date}";',
          f'contentHash = "{old_content_hash}";': f'contentHash = "{new_content_hash}";',
          f'hash = "{old_hash}";': f'hash = "{new_hash}";',
      }
      for old, new in replacements.items():
          if text.count(old) != 1:
              raise RuntimeError(f"expected exactly one recipe field: {old}")
          text = text.replace(old, new)

      recipe_path.write_text(text, encoding="utf-8")
      print(f"kimchi-docs: {old_date} -> {new_date}, {old_hash} -> {new_hash}")
      PY
    '';
  };
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "kimchi-docs";
    version = snapshotDate;

    nativeBuildInputs = [pkgs.cacert fetchDocs];
    NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    phases = ["buildPhase"];

    buildPhase = ''
      runHook preBuild
      fetch-kimchi-docs "$out" ${lib.escapeShellArg snapshotDate} "$TMPDIR/content-hash"
      read -r actual_content_hash < "$TMPDIR/content-hash"
      if [[ "$actual_content_hash" != ${lib.escapeShellArg contentHash} ]]; then
        echo "kimchi-docs: content hash mismatch" >&2
        exit 1
      fi
      runHook postBuild
    '';

    outputHash = hash;
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    passthru = {inherit updateScript;};

    meta = {
      description = "Pinned snapshot of the Kimchi documentation site";
      homepage = "https://docs.kimchi.dev/";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  }
