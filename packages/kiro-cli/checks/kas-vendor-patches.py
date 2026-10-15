"""Verify decoded vendor selections and all untouched bytes on each native builder."""

import importlib.util
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile

patcher_path, stock_path, patched_path, corpus_path, extractor = sys.argv[1:]
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


def without_changed(data, chunks, indexes):
    for start, end in sorted(((chunks[i]['start'], chunks[i]['end']) for i in indexes), reverse=True):
        data = data[:start] + data[end:]
    return data


with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "server.js"
    for relative, strip in itertools.product((False, True), repeat=2):
        names = [name for name, value in zip(patcher.FIXED, (relative, strip)) if value]
        items = patcher.replacements(names)
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
            assert after_chunk['text'] == expected, (relative, strip, i)
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
    assert Path(patched_path).read_bytes() == result, 'packaged selection differs from the two selected patches'
print('PASS: four vendor selections preserve decoded unselected text and all bytes outside changed literals; real package matches')
