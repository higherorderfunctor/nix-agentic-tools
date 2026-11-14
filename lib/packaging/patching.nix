# Recipes and checks route owned patches through this helper to refuse drift
# and backup/reject files. Source/output scans follow links; mapped dependency
# roots use physical traversal so unrelated dependency links stay outside scope.
{pkgs}: let
  inherit (pkgs) lib;
  flags = ["-p1" "--fuzz=0" "--no-backup-if-mismatch"];
  checkOption = name: type: value:
    (lib.mergeDefinitions ["patching" name] type [
      {
        file = "patching caller";
        inherit value;
      }
    ]).mergedValue;
  # A shell word allows stdenv output variables as well as escaped store paths.
  validateTree = {
    follow ? true,
    root,
  }: ''
    (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      artifacts=$(${pkgs.findutils}/bin/find ${lib.optionalString follow "-L"} ${root} \( -name '*.orig' -o -name '*.rej' \) -print)
      if [ -n "$artifacts" ]; then
        printf 'patching: backup/reject contamination:\n%s\n' "$artifacts" >&2
        exit 1
      fi
    )
  '';
  validate = root: validateTree {inherit root;};
  attrs = {patchFiles ? [], ...} @ args:
    assert lib.assertMsg (!(args ? patchFlags || args ? patches || args ? patchPhase)) "patching: use patchFiles; patchFlags, patches and patchPhase overrides are refused";
      removeAttrs args ["patchFiles"]
      // {
        patches = patchFiles;
        patchFlags = flags;
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
  # Overrides retain upstream hooks unless a caller explicitly replaces one.
  override = previous: args:
    attrs ({
        postFixup = previous.postFixup or "";
        postPatch = previous.postPatch or "";
        prePatch = previous.prePatch or "";
      }
      // args);

  # CodeQL and oxlint need Git's all-context application. Without --reject it
  # writes neither rejects nor backups; Git has no fuzz option. Only CodeQL
  # requests its existing ignore-space-change behavior.
  command = {
    backend ? "gnu",
    directory ? ".",
    ignoreSpaceChange ? false,
    patchFiles,
  }: let
    selectedBackend = checkOption "backend" (lib.types.enum ["git" "gnu"]) backend;
    ignoreWhitespace = checkOption "ignoreSpaceChange" lib.types.bool ignoreSpaceChange;
    apply = file:
      if selectedBackend == "git"
      then "${pkgs.git}/bin/git apply ${lib.escapeShellArgs ([(builtins.head flags)] ++ lib.optional ignoreWhitespace "--ignore-space-change")} -- ${lib.escapeShellArg file}"
      else "${pkgs.patch}/bin/patch ${lib.escapeShellArgs flags} < ${lib.escapeShellArg file}";
  in
    assert builtins.seq selectedBackend (lib.assertMsg (!ignoreWhitespace || selectedBackend == "git")) "patching: ignoreSpaceChange is only supported by Git"; ''
      (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        cd ${lib.escapeShellArg directory}
        ${validate "."}
        ${lib.concatMapStringsSep "\n" apply patchFiles}
        ${validate "."}
      )
    '';

  # pnpm owns dependency patches; inspect only their package roots, not unrelated
  # registry content or dependents whose directory merely carries a patch hash.
  # patchedDependencies names the existing JSON map; quote it at this boundary.
  validateDependencies = {
    directory ? "node_modules/.pnpm",
    layout ? "pnpm",
    patchedDependencies,
  }: let
    selectedLayout = checkOption "layout" (lib.types.enum ["pnpm" "runtime"]) layout;
    select = pkgs.writeText "patched-dependency-roots.mjs" ''
      import fs from "node:fs";
      import path from "node:path";
      const [directory, layout, map] = process.argv.slice(2);
      const keys = Object.keys(JSON.parse(fs.readFileSync(map, "utf8")));
      const roots = new Set();
      for (const entry of fs.readdirSync(directory).sort()) {
        for (const key of keys) {
          const split = key.lastIndexOf("@");
          const name = split > 0 ? key.slice(0, split) : key;
          const version = split > 0 ? key.slice(split + 1) : null;
          if (layout === "pnpm" && !entry.startsWith(name.replace("/", "+") + "@")) continue;
          const root = layout === "pnpm"
            ? path.join(directory, entry, "node_modules", name)
            : path.join(directory, entry);
          if (!fs.existsSync(path.join(root, "package.json"))) continue;
          const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
          if (pkg.name === name && (version === null || pkg.version === version)) roots.add(root);
        }
      }
      for (const root of roots) process.stdout.write(root + "\0");
    '';
  in ''
    (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # A pipeline propagates selector failure, unlike process substitution.
      ${pkgs.nodejs}/bin/node ${select} ${lib.escapeShellArgs [directory selectedLayout patchedDependencies]} |
        # Dependency links leave the patched package; select each peer itself.
        while IFS= read -r -d $'\0' patchedRoot; do
          ${validateTree {
      follow = false;
      root = ''"$patchedRoot"'';
    }}
        done
    )
  '';

  # Keep nixpkgs' hook order, metadata and source passthru.
  source = args: pkgs.applyPatches (attrs args);
}
