{
  lib,
  pathExists ? builtins.pathExists,
  readFile ? builtins.readFile,
  readFileType ? builtins.readFileType,
}: gitRoot: let
  canonicalize = path:
    if lib.hasPrefix "/" path
    then toString (/. + path)
    else throw "Codex Git permission discovery expected an absolute path, got ${path}";
  resolvePath = base: path:
    canonicalize (
      if lib.hasPrefix "/" path
      then path
      else "${base}/${path}"
    );
  readSingleLine = label: path: let
    value = lib.removeSuffix "\r" (lib.removeSuffix "\n" (readFile path));
  in
    if value == "" || lib.hasInfix "\n" value || lib.hasInfix "\r" value
    then throw "Codex Git permission discovery found an invalid ${label} in ${path}"
    else value;
  requireDirectory = label: path:
    if pathExists path && readFileType path == "directory"
    then path
    else throw "Codex Git permission discovery expected ${label} to be a directory: ${path}";
  requireRegularFile = label: path:
    if pathExists path && readFileType path == "regular"
    then path
    else throw "Codex Git permission discovery expected ${label} to be a regular file: ${path}";
  requireGitDirectory = path: let
    gitDir = requireDirectory "gitdir target" path;
  in
    builtins.seq (requireRegularFile "Git HEAD" "${gitDir}/HEAD") gitDir;
  requireCommonDirectory = path: let
    commonDir = requireDirectory "Git common directory" path;
  in
    builtins.seq (requireRegularFile "Git config" "${commonDir}/config") (
      builtins.seq (requireDirectory "Git object database" "${commonDir}/objects") commonDir
    );
  resolveFromGitDirectory = path: let
    gitDir = requireGitDirectory path;
    commonDirFile = "${gitDir}/commondir";
  in
    if !pathExists commonDirFile
    then requireCommonDirectory gitDir
    else if readFileType commonDirFile != "regular"
    then throw "Codex Git permission discovery expected commondir to be a regular file: ${commonDirFile}"
    else
      requireCommonDirectory (
        resolvePath gitDir (readSingleLine "commondir path" commonDirFile)
      );
  canonicalGitRoot = canonicalize gitRoot;
  dotGit = "${canonicalGitRoot}/.git";
  dotGitType =
    if pathExists dotGit
    then readFileType dotGit
    else null;
in
  if dotGitType == null
  then null
  else if dotGitType == "directory"
  then resolveFromGitDirectory (canonicalize dotGit)
  else if dotGitType == "regular"
  then let
    pointerMatch = builtins.match "gitdir: (.+)" (readSingleLine "gitdir pointer" dotGit);
    gitDir =
      if pointerMatch == null
      then throw "Codex Git permission discovery found a malformed gitdir pointer in ${dotGit}"
      else resolvePath canonicalGitRoot (lib.head pointerMatch);
  in
    resolveFromGitDirectory gitDir
  else throw "Codex Git permission discovery expected ${dotGit} to be a directory or gitdir pointer file"
