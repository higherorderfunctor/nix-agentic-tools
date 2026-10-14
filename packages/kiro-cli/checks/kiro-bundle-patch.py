"""Exercise decoded patching, interpolation preservation and fail-closed drift."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PATCHER, EXTRACTOR = sys.argv[1:]
sys.argv[1:] = []
spec = importlib.util.spec_from_file_location("patcher", PATCHER)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
IDENTITY = 'Custom "identity". Another sentence!'


def extract(data):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "source.js"
        path.write_bytes(data)
        result = subprocess.run([EXTRACTOR, str(path)], capture_output=True, check=True)
        return json.loads(result.stdout)


def bundle(quote='"'):
    def literal(text):
        encoded = json.dumps(text, ensure_ascii=True)[1:-1]
        if quote == "'":
            encoded = encoded.replace("'", "\\'")
        if quote == '`':
            encoded = encoded.replace('`', '\\`').replace('${', '\\${')
        return quote + encoded + quote
    return ("// 😀 exercises UTF-16 versus UTF-8 offsets\n"
            + "const heading='unrelated';function identity(){return " + literal(patcher.IDENTITY_SENTENCE + " Terminal guidance.") + ";}\n"
            + "var steering=" + literal("Before\n\n" + patcher.WORKTREE_PARAGRAPH + "After") + ";\n"
            + "var workflow=" + literal(patcher.FILE_CHECK_PARAGRAPH) + ";\n"
            + "function assembled(value){return `before ${value} after ${identity()} tail`;}").encode()


class PatchTests(unittest.TestCase):
    def test_quotes_selection_and_observed_values(self):
        for quote in ('"', "'", '`'):
            data = bundle(quote)
            corpus = extract(data)
            for identity in (IDENTITY, None):
                with self.subTest(quote=quote, identity=identity):
                    result, errors = patcher.patch(data, corpus, patcher.replacements(identity))
                    self.assertEqual(errors, [])
                    observed = json.loads(subprocess.check_output([
                        "node", "-e", result.decode() + "console.log(JSON.stringify([identity(),steering,workflow,assembled('RUNTIME')]));"
                    ]))
                    sentence = identity or patcher.IDENTITY_SENTENCE
                    self.assertEqual(observed[0], sentence + ' Terminal guidance.')
                    self.assertEqual(observed[1], "Before\n\n" + patcher.WORKTREE_PARAGRAPH + "After")
                    self.assertEqual(observed[2], patcher.FILE_CHECK_PARAGRAPH)
                    self.assertEqual(observed[3], 'before RUNTIME after ' + sentence + ' Terminal guidance. tail')
                    if identity is None:
                        self.assertEqual(result, data)

    def test_interpolation_is_not_executed_and_boundaries_are_exact(self):
        data = b"const x=`head ${process.exit(99)} middle ${`nested ${unknown}`} tail`;"
        corpus = extract(data)
        outer = corpus['templates'][0]
        self.assertEqual([p['expression'] for p in outer['parts'] if 'expression' in p], ['process.exit(99)', '`nested ${unknown}`'])
        self.assertEqual([corpus['chunks'][p['chunk']]['text'] for p in outer['parts'] if 'chunk' in p], ['head ', ' middle ', ' tail'])
        result, errors = patcher.patch(data, corpus, [('fixture', ' middle ', ' ${literal} ` quote \\ newline\n')])
        self.assertEqual(errors, [])
        after = extract(result)
        self.assertEqual([p['expression'] for p in after['templates'][0]['parts'] if 'expression' in p], ['process.exit(99)', '`nested ${unknown}`'])
        self.assertEqual(after['chunks'][1]['text'], ' ${literal} ` quote \\ newline\n')

    def test_drift_and_stale_corpus_refuse_without_partial_output(self):
        data = bundle()
        corpus = extract(data)
        self.assertEqual(patcher.patch(data + b' ', corpus, [])[1], ['corpus does not describe the source bundle'])
        for name, source, _ in patcher.replacements(IDENTITY):
            for count in (0, 2):
                changed = data.replace(json.dumps(source)[1:-1].encode(), b'changed') if count == 0 else data + ('\nconst duplicate=' + json.dumps(source) + ';').encode()
                changed_corpus = extract(changed)
                result, errors = patcher.patch(changed, changed_corpus, patcher.replacements(IDENTITY))
                self.assertIsNone(result)
                self.assertIn(f'{name}: expected decoded source text once, found {count}; bundle drift', errors)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'in.js').write_bytes(data + b' ')
            (root/'corpus.json').write_text(json.dumps(corpus))
            (root/'out.js').write_bytes(b'untouched')
            result = subprocess.run([sys.executable, PATCHER, str(root/'in.js'), str(root/'corpus.json'), str(root/'out.js'), '--check'], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual((root/'out.js').read_bytes(), b'untouched')

    def test_lone_surrogates_and_template_holes_stay_distinct(self):
        data = b'const x="\\ud800";const y=`vendor ${runtime} guidance`;'
        corpus = extract(data)
        self.assertEqual(corpus['chunks'][0]['text'], '\ud800')
        result, errors = patcher.patch(data, corpus, [('fixture', 'vendor guidance', 'ours')])
        self.assertIsNone(result)
        self.assertEqual(errors, ['fixture: expected decoded source text once, found 0; bundle drift'])

    def test_tagged_template_patch_is_refused(self):
        data = b'const prompt=custom`vendor guidance`;'
        result, errors = patcher.patch(data, extract(data), [('fixture', 'vendor', 'ours')])
        self.assertIsNone(result)
        self.assertEqual(errors, ['fixture: tagged template has runtime-defined decoding'])

    def test_invalid_identity_is_rejected(self):
        for identity in ('', 'no punctuation', 'Bad `identity`.', 'Bad ${identity}.'):
            with self.subTest(identity=identity), self.assertRaisesRegex(ValueError, 'identity:'):
                patcher.replacements(identity)


if __name__ == '__main__':
    unittest.main()
