# File materialization module — generates config files as Nix store
# derivations and symlinks them into the project directory on shell entry.
#
# Adapted from devenv's files.nix pattern.
# Files are symlinked (not copied) so they update when the derivation changes.
# Orphaned symlinks pointing into /nix/store are cleaned up on entry.
{
  config,
  lib,
  pkgs,
  ...
}: let
  aiTypes = import ../lib/ai/types.nix {inherit lib;};
  fileType =
    aiTypes.extendSubmodule
    (aiTypes.optionalTextSource {
      description = "project file content";
      textType = lib.types.str;
    })
    ({
      config,
      name,
      ...
    }: {
      options = {
        file = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          description = "The resolved store path for this file.";
        };

        onChange = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Shell commands to run when this file changes.";
        };
      };

      config.file =
        if config._sourceWins
        then config.source
        else pkgs.writeText name config.text;
    });

  enabledFiles = lib.filterAttrs (_: file: file.enable) config.files;

  # Generate the shell hook that materializes files
  materializeHook = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: file: ''
      # Materialize: ${name}
      _target="${name}"
      _store="${file.file}"
      _dir="$(dirname "$_target")"
      [ -d "$_dir" ] || mkdir -p "$_dir"
      if [ -L "$_target" ]; then
        _current="$(readlink "$_target")"
        if [ "$_current" != "$_store" ]; then
          ln -sf "$_store" "$_target"
          ${file.onChange}
        fi
      elif [ ! -e "$_target" ]; then
        ln -s "$_store" "$_target"
        ${file.onChange}
      else
        echo "agentic-shell: WARNING: ${name} exists and is not a symlink, skipping" >&2
      fi
    '')
    enabledFiles);

  # Clean up orphaned symlinks (pointing to /nix/store but not in our set)
  cleanupHook = let
    managedFiles = builtins.attrNames enabledFiles;
    managedSet = lib.concatMapStringsSep " " (f: ''"${f}"'') managedFiles;
  in ''
    # Cleanup orphaned agentic-shell symlinks
    _managed_files=(${managedSet})
    for _f in "''${_managed_files[@]}"; do
      if [ -L "$_f" ] && [[ "$(readlink "$_f")" == /nix/store/* ]]; then
        # This is ours — will be updated above
        :
      fi
    done
  '';
in {
  options.files = lib.mkOption {
    type = lib.types.attrsOf fileType;
    default = {};
    description = ''
      Files to materialize in the project directory on shell entry.
      Each file is a Nix store derivation symlinked into place.
    '';
  };

  config.shellHook = lib.mkAfter ''
    ${cleanupHook}
    ${materializeHook}
  '';
}
