#!/usr/bin/env python3
"""Opt-in CodeQL databases: one published generation per checkout and name."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def link(target, destination):
    temporary = destination.with_name(destination.name + ".next")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    temporary.replace(destination)


def archive(root, commit, destination):
    destination.mkdir()
    with tempfile.TemporaryFile() as stream:
        subprocess.run(["git", "archive", commit], cwd=root, stdout=stream, check=True)
        stream.seek(0)
        with tarfile.open(fileobj=stream) as tree:
            tree.extractall(destination, filter="tar")


def tools(root, spec):
    system = run("nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem")
    expression = "c: { engine = toString c.engine; create = toString c.createDatabase; }"
    if spec["source"] == "git":
        expression = """c: { engine = toString c.engine; create = toString c.createDatabase;
          warm = toString c.warmEngine; manifest = c.extractorManifest; pack = c.queries.name; }"""
    attribute = f".#ciPackages.{system}.{spec['codeql']}"
    result = json.loads(run("nix", "eval", "--json", attribute, "--apply", expression, cwd=root))
    return attribute, result


def changes(root, base, extensions):
    # --no-renames includes both sides of renames, including deleted files.
    names = subprocess.check_output(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, "--"], cwd=root
    ).split(b"\0")
    names += subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root
    ).split(b"\0")
    return sorted({os.fsdecode(name) for name in names if name and not os.fsdecode(name).startswith(".devenv/state/codeql/")
                   and Path(os.fsdecode(name)).suffix in extensions})


def content_stamp(root, names):
    return [(name, hashlib.sha256((root / name).read_bytes()).hexdigest()
             if (root / name).is_file() else None) for name in names]


def create(root, spec, resolved, generation, commit=None):
    command = [str(Path(resolved["create"]) / "bin" / spec["create"]), str(generation)]
    if commit:
        source = generation / "snapshot"
        archive(root, commit, source)
        command.append(str(source))
    subprocess.run(command, cwd=root, check=True)
    if commit:
        shutil.rmtree(source)


def warm(resolved, database, overlay):
    engine = str(Path(resolved["warm"]) / "bin/codeql")
    # Ordinary .qlx plans cannot execute in overlay mode. Let CodeQL compile
    # from the standing pack's source against the overlay-prepared database.
    options = ["--cache-at-frontier", "--no-use-precompiled"] if overlay else ["--no-cache-at-frontier"]
    subprocess.run([engine, "database", "run-queries", str(database), resolved["pack"],
                    *options, "--threads=4", "--ram=6000"], check=True)
    subprocess.run([engine, "database", "cleanup", str(database),
                    "--cache-cleanup=" + ("overlay" if overlay else "trim")], check=True)


def supports_overlay(resolved):
    # Read the actual extractor, rather than assuming all CLI languages support it.
    return any(line.startswith("overlay_support_version:") for line in Path(resolved["manifest"]).read_text().splitlines())


def git_generation(root, name, spec, resolved, generation, head, base, overlay, working):
    common = Path(run("git", "rev-parse", "--path-format=absolute", "--git-common-dir", cwd=root))
    shared = common / "codeql" / name
    key = digest([base, resolved, spec, overlay, hashlib.sha256(Path(__file__).read_bytes()).hexdigest()])
    cached = shared / key
    with locked(shared / "base.lock"):
        if not cached.is_dir():
            temporary = Path(tempfile.mkdtemp(prefix="base.", dir=shared))
            try:
                if overlay:
                    archive(root, base, temporary / "source")
                    subprocess.run([str(Path(resolved["engine"]) / "bin/codeql"), "database", "create",
                                    str(temporary / "db"), f"--language={spec['language']}",
                                    "--build-mode=none", f"--source-root={temporary / 'source'}",
                                    "--overlay-base", "--threads=4", "--ram=6000"], check=True)
                else:
                    create(root, spec, resolved, temporary, base)
                warm(resolved, temporary / "db", overlay)
                temporary.rename(cached)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
        # A real copy: overlay imports and query caches mutate database files.
        if overlay or head == base:
            subprocess.run(["cp", "-a", str(cached / "db"), str(generation / "db")], check=True)
    if overlay:
        names = changes(root, base, spec["extensions"])
        # Freeze the committed tree plus language edits before extraction, and
        # refuse a concurrent edit rather than stamp content we did not use.
        source = generation / "source"
        archive(root, head, source)
        for name in names:
            destination = source / name
            destination.unlink(missing_ok=True)
            if (root / name).is_file():
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((root / name).read_bytes())
        if content_stamp(source, names) != working:
            raise RuntimeError("source changed while taking the overlay snapshot; rerun up")
        change_file = generation / "changes.json"
        change_file.write_text(json.dumps({"changes": names}) + "\n")
        subprocess.run([str(Path(resolved["engine"]) / "bin/codeql"), "database", "create",
                        str(generation / "db"), f"--language={spec['language']}", "--build-mode=none",
                        f"--source-root={source}", f"--overlay-changes={change_file}",
                        "--threads=4", "--ram=6000"], check=True)
    elif head != base:
        create(root, spec, resolved, generation, head)


def lifecycle(root, name, spec, action, existing=False):
    state = root / ".devenv/state/codeql" / name
    # Hooks do not activate a database, including when down wins the lock race.
    if existing and not (state / "db").is_symlink():
        return
    with locked(state / "lock"):
        database = state / "db"
        if existing and not database.is_symlink():
            return
        old = database.resolve() if database.is_symlink() else None
        if old and (old.name != "db" or old.parent.parent != state.resolve()
                    or not old.parent.name.startswith("generation.")):
            raise RuntimeError(f"refusing unmanaged database target: {old}")
        if database.exists() and not database.is_symlink():
            raise RuntimeError(f"{database} is a legacy directory; move it aside before running up")
        if action == "down":
            database.unlink(missing_ok=True)
            (state / "stamp").unlink(missing_ok=True)
            (state / "engine").unlink(missing_ok=True)
            if old and old.parent.is_dir():
                shutil.rmtree(old.parent)
            return
        attribute, resolved = tools(root, spec)
        # Realize the manifest before inspecting capabilities; all tool paths
        # participate in both the worktree stamp and shared-base key.
        subprocess.run(["nix", "build", "--no-link", attribute + ".engine", attribute + ".createDatabase"]
                       + ([attribute + ".warmEngine"] if spec["source"] == "git" else []), cwd=root, check=True)
        inputs = {"spec": spec, "tools": resolved, "lifecycle": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        head = base = None
        overlay = False
        if spec["source"] == "git":
            head = run("git", "rev-parse", "HEAD", cwd=root)
            base = run("git", "merge-base", head, "origin/main", cwd=root)
            overlay = supports_overlay(resolved)
            inputs.update(head=head, base=base, overlay=overlay)
            if overlay:
                inputs["working"] = content_stamp(root, changes(root, base, spec["extensions"]))
        stamp = json.dumps(inputs, sort_keys=True, separators=(",", ":")) + "\n"
        if action == "up" and old and (state / "stamp").exists() and (state / "stamp").read_text() == stamp:
            print(f"{name}: current ({database})")
            return
        generation = Path(tempfile.mkdtemp(prefix="generation.", dir=state))
        try:
            # An indirect root follows the generation's actual engine link, not
            # the public link that changes when another generation is published.
            subprocess.run(["nix-store", "--realize", resolved["engine"], "--add-root",
                            str(generation / "engine"), "--indirect"], cwd=root, check=True)
            if spec["source"] == "git":
                git_generation(root, name, spec, resolved, generation, head, base, overlay, inputs.get("working"))
            else:
                create(root, spec, resolved, generation)
            if not (generation / "db").is_dir():
                raise RuntimeError("creator did not produce a database")
            (generation / "stamp").write_text(stamp)
            # Publish only complete generations; the adjacent stamp is a link
            # through db, so it changes in the same atomic operation.
            link("db/../engine", state / "engine")
            link("db/../stamp", state / "stamp")
            link(str(generation / "db"), database)
        except BaseException:
            shutil.rmtree(generation)
            raise
        if old and old.parent.is_dir():
            shutil.rmtree(old.parent)
        print(f"{name}: published {database.resolve()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["up", "refresh", "down", "hook", "refresh-existing"])
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    root = Path(run("git", "rev-parse", "--show-toplevel"))
    specs = json.loads((root / "dev/codeql-databases.json").read_text())
    if args.action == "hook":
        if os.environ.get("PRE_COMMIT_CHECKOUT_TYPE") == "0":
            return
        for name in specs:
            state = root / ".devenv/state/codeql" / name
            if not (state / "db").is_symlink():
                continue
            with (state / "refresh.log").open("a") as log:
                subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "refresh-existing", name],
                                 cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True, close_fds=True)
    else:
        if args.name not in specs:
            parser.error("name must be one of " + ", ".join(specs))
        lifecycle(root, args.name, specs[args.name], "up" if args.action == "refresh-existing" else args.action,
                  existing=args.action == "refresh-existing")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"codeql-lifecycle: {error}", file=sys.stderr)
        # A lifecycle hook is always advisory, including a removed checkout.
        sys.exit(0 if sys.argv[1:2] == ["hook"] else 1)
