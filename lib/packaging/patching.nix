# Repository-owned patch applications use this group, never caller patchFlags
# or applyPatches: offset backups otherwise leak into extracted sources/checks.
{pkgs}: let
  inherit (pkgs) lib;
  flags = strip: ["-p${toString strip}" "--fuzz=0" "--no-backup-if-mismatch"];
  validStrip = strip: assert lib.assertMsg (builtins.isInt strip && strip >= 0) "patching: strip must be a nonnegative integer"; strip;
  # A shell word allows stdenv output variables as well as escaped store paths.
  validate = root: ''
    (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      artifacts=$(${pkgs.findutils}/bin/find -L ${root} \( -name '*.orig' -o -name '*.rej' \) -print)
      if [ -n "$artifacts" ]; then
        printf 'patching: backup/reject contamination:\n%s\n' "$artifacts" >&2
        exit 1
      fi
    )
  '';
  attrs = {
    patchFiles ? [],
    strip ? 1,
    ...
  } @ args:
    assert lib.assertMsg (!(args ? patchFlags || args ? patches || args ? patchPhase)) "patching: use patchFiles and strip; patchFlags, patches and patchPhase overrides are refused";
      removeAttrs args ["patchFiles" "strip"]
      // {
        patches = patchFiles;
        patchFlags = flags (validStrip strip);
        prePatch = validate "." + (args.prePatch or "");
        postPatch = (args.postPatch or "") + "\n" + validate ".";
        postFixup =
          (args.postFixup or "")
          + "\n"
          + ''
            for patchOutput in $(getAllOutputNames); do
              ${validate ''"''${!patchOutput}"''}
            done
          '';
      };
in {
  inherit attrs validate;

  # CodeQL and oxlint need Git's all-context application. Without --reject it
  # writes neither rejects nor backups; Git has no fuzz option. Only CodeQL
  # requests its existing ignore-space-change behavior.
  command = {
    backend ? "gnu",
    directory ? ".",
    ignoreSpaceChange ? false,
    patchFiles,
    strip ? 1,
  }:
    assert lib.assertMsg (lib.elem backend ["git" "gnu"]) "patching: backend must be git or gnu";
    assert lib.assertMsg (!ignoreSpaceChange || backend == "git") "patching: ignoreSpaceChange is only supported by Git"; let
      patchFlags = flags (validStrip strip);
      apply = file:
        if backend == "git"
        then "${pkgs.git}/bin/git apply ${lib.escapeShellArgs ([(builtins.head patchFlags)] ++ lib.optional ignoreSpaceChange "--ignore-space-change")} -- ${lib.escapeShellArg file}"
        else "${pkgs.patch}/bin/patch ${lib.escapeShellArgs patchFlags} < ${lib.escapeShellArg file}";
    in ''
      (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        cd ${lib.escapeShellArg directory}
        ${validate "."}
        ${lib.concatMapStringsSep "\n" apply patchFiles}
        ${validate "."}
      )
    '';

  # Keep nixpkgs' decompression, hook order, metadata and source passthru.
  source = args: pkgs.applyPatches (attrs args);
}
