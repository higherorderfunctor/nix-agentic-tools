"""Verify decoded vendor selections and all untouched bytes on each native builder."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

patcher_path, stock_path, installed_stock_path, patched_path, corpus_path, extractor, hooks, typescript = sys.argv[1:]
spec = importlib.util.spec_from_file_location("patcher", patcher_path)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
stock = Path(stock_path).read_bytes()
corpus = json.loads(Path(corpus_path).read_text())
assert set(corpus['groups']) == {'identity', 'systemFeatures', 'vibe', 'workflowCreator', 'workflowOrchestration'}
# These semantic roots prove broad extraction includes system guidance and
# runtime substitutions, not merely three replacement paragraphs.
for name in ('systemFeatures', 'vibe'):
    group = corpus['groups'][name]
    chunk = corpus['chunks'][group['chunk']]
    assert any(t['start'] <= chunk['start'] < t['end'] and any('expression' in p for p in t['parts']) for t in corpus['templates'])
assert any('<steering>' in chunk['text'] for chunk in corpus['chunks'])
assert any('<system_information>' in chunk['text'] for chunk in corpus['chunks'])
identity = "Custom identity. Another sentence!"


def without_changed(data, chunks, indexes):
    for start, end in sorted(((chunks[i]['start'], chunks[i]['end']) for i in indexes), reverse=True):
        data = data[:start] + data[end:]
    return data


with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "server.js"
    for enabled in (False, True):
        items = patcher.replacements(identity if enabled else None)
        result, errors = patcher.patch(stock, corpus, items)
        assert not errors, errors
        path.write_bytes(result)
        subprocess.run(["node", "--check", str(path)], check=True)
        after = json.loads(subprocess.check_output([extractor, str(path)]))
        assert len(after['chunks']) == len(corpus['chunks'])
        changed = []
        for i, (before_chunk, after_chunk) in enumerate(zip(corpus['chunks'], after['chunks'])):
            expected = before_chunk['text']
            for _, source, replacement in items:
                expected = expected.replace(source, replacement)
            assert after_chunk['text'] == expected, (enabled, i)
            if expected != before_chunk['text']:
                changed.append(i)
                # Execute only this parser-identified standalone literal. The
                # patched vendor sites contain no runtime interpolations.
                assert after_chunk['kind'] in ('StringLiteral', 'FirstTemplateToken')
                raw = result[after_chunk['start']:after_chunk['end']]
                observed = subprocess.check_output(['node', '-e', 'process.stdout.write(' + raw.decode() + ')'])
                assert observed.decode() == expected
        assert without_changed(stock, corpus['chunks'], changed) == without_changed(result, after['chunks'], changed)
        if not items:
            assert result == stock
        defaults = Path(tmp) / "prompt-defaults"
        identity_path = Path(tmp) / "identity.txt"
        identity_path.write_text(identity)
        command = [sys.executable, patcher_path, stock_path, corpus_path, str(path), "--prompt-defaults", str(defaults)]
        if enabled:
            command += ["--identity-file", str(identity_path)]
        subprocess.run(command, check=True)
        selected_corpus = Path(tmp) / "selected-corpus.json"
        selected_corpus.write_text(json.dumps(after))
        subprocess.run(["node", hooks, str(path), str(defaults), typescript, str(selected_corpus)], check=True)
        subprocess.run(["node", "--check", str(path)], check=True)
        assert (defaults / "identity.txt").read_text() == (identity if enabled else patcher.IDENTITY_SENTENCE)
        assert (defaults / "worktreeGuidance.txt").read_text() == patcher.WORKTREE_PARAGRAPH
        assert (defaults / "workflowFileCheckGuidance.txt").read_text() == patcher.FILE_CHECK_PARAGRAPH
        installed_path = patched_path if enabled else installed_stock_path
        assert Path(installed_path).read_bytes() == path.read_bytes(), f'packaged selection {enabled} differs from text and session hooks'
        installed_defaults = Path(installed_path).parent / "prompt-defaults"
        expected_files = {entry.name: entry.read_bytes() for entry in defaults.iterdir()}
        actual_files = {entry.name: entry.read_bytes() for entry in installed_defaults.iterdir()}
        assert actual_files == expected_files, f'packaged defaults {enabled} differ from generated defaults'
print('PASS: two selections preserve unselected source before hooks; selected default files, hook syntax and real package agree')
