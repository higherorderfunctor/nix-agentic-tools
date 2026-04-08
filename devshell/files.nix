# File materialization module — generates config files as Nix store
# derivations and symlinks them into the project directory on shell entry.
#
# Adapted from devenv's files.nix pattern.
# Files are symlinked (not copied) so they update when the derivation changes.
#
# NOTE: orphan symlink cleanup is NOT yet implemented. If a file is removed
# from the `files` option between two shell entries, the prior symlink stays
# in the project directory pointing at a (potentially garbage-collected)
# store path. Tracked as a backlog item.
{
  config,
  lib,
  pkgs,
  ...
}: let
  fileType = lib.types.submodule ({name, ...}: {
    options = {
      text = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Text content to write to the file.";
      };

      json = lib.mkOption {
        type = lib.types.nullOr lib.types.anything;
        default = null;
        description = "JSON value to serialize to the file.";
      };

      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to a file to symlink.";
      };

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

    config.file = let
      jsonFile = pkgs.writeText name (builtins.toJSON config.json);
      textFile = pkgs.writeText name config.text;
    in
      if config.source != null
      then config.source
      else if config.json != null
      then jsonFile
      else if config.text != null
      then textFile
      else builtins.throw "File '${name}' must have one of: text, json, or source.";
  });

  enabledFiles = lib.filterAttrs (_: f:
    f.text != null || f.json != null || f.source != null)
  config.files;

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
    ${materializeHook}
  '';
}
