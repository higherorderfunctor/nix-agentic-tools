{
  lib,
  pkgs,
}: package: grammars: let
  grammarLanguages = map (grammar: grammar.language or "") grammars;
  grammarEntries =
    map
    (grammar: {
      inherit (grammar) language;
      parser = "${grammar}/parser";
      symbol = "tree_sitter_${lib.replaceStrings ["-"] ["_"] grammar.language}";
    })
    grammars;
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
in
  if grammars == []
  then package
  else
    assert lib.assertMsg (package ? overridePythonAttrs)
    "semble.withGrammars requires a Python package exposing overridePythonAttrs";
    assert lib.assertMsg (lib.all (language: language != "") grammarLanguages)
    "semble.withGrammars grammar packages must expose a non-empty language attribute";
    assert lib.assertMsg (lib.length (lib.unique grammarLanguages) == lib.length grammarLanguages)
    "semble.withGrammars grammar language names must be unique";
      (package.overridePythonAttrs (old: {
        patches = (old.patches or []) ++ [../patches/extra-grammars.patch];
        postPatch =
          (old.postPatch or "")
          + ''
            ${pkgs.coreutils}/bin/cp ${grammarLoader} src/semble/extra_grammars.py
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
          };
      }
