# Installed scribe implementation only: no corpus, grammar values, semantics
# model, board assets, tests, or mutable project configuration. Keep additions
# explicit so a new runtime dependency cannot widen this source boundary.
{lib}:
lib.fileset.toSource {
  root = ../../../dev/scripts;
  fileset = lib.fileset.unions [
    ../../../dev/scripts/scribe_client.py
    ../../../dev/scripts/scribe_cmd.py
    ../../../dev/scripts/scribe_contract.py
    ../../../dev/scripts/scribe_daemon.py
    ../../../dev/scripts/scribe_diff.py
    ../../../dev/scripts/scribe_ops.py
    ../../../dev/scripts/scribe_paths.py
    ../../../dev/scripts/scribe_protocol.py
    ../../../dev/scripts/scribe_rpc.py
    ../../../dev/scripts/scribe_verbs.py
    ../../../dev/scripts/scribe_workspace.py
    ../../../dev/scripts/sdoc_extractors/__init__.py
    ../../../dev/scripts/sdoc_extractors/bash.py
    ../../../dev/scripts/sdoc_extractors/nix.py
    ../../../dev/scripts/sdoc_extractors/register.py
    ../../../dev/scripts/sdoc_extractors/registry.py
    ../../../dev/scripts/sdoc_extractors/strictdoc_reader.py
    ../../../dev/scripts/sdoc_extractors/tree_sitter_extractor.py
    ../../../dev/scripts/sdoc_model.py
  ];
}
