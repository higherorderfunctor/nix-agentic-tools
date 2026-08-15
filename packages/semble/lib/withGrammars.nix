{
  lib,
  pkgs,
}: package: grammars: pathMappings: let
  grammarLanguages = map (grammar: grammar.language or "") grammars;
  mappingPatterns = lib.concatMap (mapping: mapping.patterns or []) pathMappings;
  pathMappingsValid =
    lib.all (
      mapping:
        builtins.isAttrs mapping
        && lib.elem (mapping.content or null) ["code" "config" "docs"]
        && builtins.isString (mapping.language or null)
        && mapping.language != ""
        && builtins.isList (mapping.patterns or null)
        && mapping.patterns != []
        && lib.all (pattern: builtins.isString pattern && pattern != "") mapping.patterns
    )
    pathMappings;
  pathMappingPatternsUnique = lib.length (lib.unique mappingPatterns) == lib.length mappingPatterns;
  grammarEntries =
    map
    (grammar: {
      inherit (grammar) language;
      parser = "${grammar}/parser";
      symbol = "tree_sitter_${lib.replaceStrings ["-"] ["_"] grammar.language}";
    })
    grammars;
  customizationFingerprint = builtins.hashString "sha256" (builtins.toJSON {
    inherit grammarEntries pathMappings;
  });
  grammarLoader = pkgs.writeText "semble-extra-grammars.py" ''
    # cspell:ignore argtypes pythonapi restype
    from __future__ import annotations

    import ctypes
    from functools import cache

    from semble_grammars import GrammarLoadError, LanguageNotFoundError
    from tree_sitter import Language, Parser

    _GRAMMARS = ${builtins.toJSON (lib.listToAttrs (map (entry: lib.nameValuePair entry.language entry) grammarEntries))}
    _LOADED_LIBRARIES: dict[str, ctypes.CDLL] = {}


    def _load_capsule(path: str, symbol: str) -> object:
        try:
            library = ctypes.CDLL(path)
        except OSError as exc:
            raise GrammarLoadError(f"Failed to load extra grammar {path!r}") from exc
        _LOADED_LIBRARIES[path] = library

        try:
            entry_point = getattr(library, symbol)
        except AttributeError as exc:
            raise GrammarLoadError(f"{path!r}: missing expected symbol {symbol!r}") from exc

        entry_point.restype = ctypes.c_void_p
        language_pointer = entry_point()
        if not language_pointer:
            raise GrammarLoadError(f"{path!r}: {symbol}() returned a null language pointer")

        py_capsule_new = ctypes.pythonapi.PyCapsule_New
        py_capsule_new.restype = ctypes.py_object
        py_capsule_new.argtypes = (ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p)
        return py_capsule_new(language_pointer, b"tree_sitter.Language", None)


    @cache
    def get_parser(name: str) -> Parser:
        entry = _GRAMMARS.get(name)
        if entry is None:
            raise LanguageNotFoundError(f"Unknown extra language {name!r}")
        capsule = _load_capsule(entry["parser"], entry["symbol"])
        return Parser(Language(capsule))
  '';
  pathMappingLoader = pkgs.writeText "semble-path-mappings.py" ''
    from __future__ import annotations

    from fnmatch import fnmatchcase
    from pathlib import Path
    from typing import Any

    CUSTOMIZATION_FINGERPRINT = "${customizationFingerprint}"
    _MAPPINGS: list[dict[str, Any]] = ${builtins.toJSON pathMappings}


    def _find_mapping(file_path: Path, root: Path | None = None) -> dict[str, Any] | None:
        try:
            relative = file_path.relative_to(root).as_posix() if root is not None else file_path.as_posix()
        except ValueError:
            relative = file_path.as_posix()

        for mapping in _MAPPINGS:
            for pattern in mapping["patterns"]:
                candidate = relative if "/" in pattern else file_path.name
                if fnmatchcase(candidate, pattern):
                    return mapping
        return None


    def get_mapped_language(file_path: Path, root: Path | None = None) -> str | None:
        mapping = _find_mapping(file_path, root)
        return None if mapping is None else mapping["language"]


    def get_mapped_content(file_path: Path, root: Path) -> str | None:
        mapping = _find_mapping(file_path, root)
        return None if mapping is None else mapping["content"]
  '';
in
  if grammars == [] && pathMappings == []
  then package
  else
    assert lib.assertMsg (package ? overridePythonAttrs)
    "semble.customizePackage requires a Python package exposing overridePythonAttrs";
    assert lib.assertMsg (lib.all (language: language != "") grammarLanguages)
    "semble.customizePackage grammar packages must expose a non-empty language attribute";
    assert lib.assertMsg (lib.length (lib.unique grammarLanguages) == lib.length grammarLanguages)
    "semble.customizePackage grammar language names must be unique";
    assert lib.assertMsg pathMappingsValid
    "semble.customizePackage path mappings require code/config/docs content, a non-empty language, and non-empty string patterns";
    assert lib.assertMsg pathMappingPatternsUnique
    "semble.customizePackage path mapping patterns must be unique";
      (package.overridePythonAttrs (old: {
        patches = (old.patches or []) ++ [../patches/extra-grammars.patch];
        postPatch =
          (old.postPatch or "")
          + ''
            ${pkgs.coreutils}/bin/cp ${grammarLoader} src/semble/extra_grammars.py
            ${pkgs.coreutils}/bin/cp ${pathMappingLoader} src/semble/path_mappings.py
          '';
      }))
      // {
        # `overridePythonAttrs` sees the derivation before a caller or overlay
        # extends it as a plain attrset. Merge from the public package value so
        # metadata such as updateFlakeInput survives grammar injection.
        passthru =
          (package.passthru or {})
          // {
            sembleExtraGrammarLanguages = grammarLanguages;
            semblePathMappings = pathMappings;
          };
      }
