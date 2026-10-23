"""Run only explicitly named unittest files; reject empty or all-skipped suites."""

import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest


def run_suite(path):
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    executed = result.testsRun - len(result.skipped)
    print(f"{path}: {result.testsRun} tests, {executed} executed", flush=True)
    return result.wasSuccessful() and executed > 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    if args.suite:
        if len(args.files) != 1:
            parser.error("a suite worker accepts exactly one file")
        path = args.files[0].resolve(strict=True)
        try:
            return 0 if run_suite(path) else 1
        except SystemExit as error:
            print(f"{path}: suite exited before completion ({error})", file=sys.stderr)
            return 1
    passed = True
    for path in args.files:
        # Separate processes isolate imports and unittest state between domains.
        result = subprocess.run([sys.executable, __file__, "--suite", str(path)])
        passed = result.returncode == 0 and passed
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
