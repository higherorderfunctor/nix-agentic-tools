#!/usr/bin/env python3
"""Opt-in CodeQL databases: one published generation per checkout and name."""

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time


CACHE_MB = 512
ORPHAN_GRACE_SECONDS = 300


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


def cleanup(resolved, database, mode="fit"):
    subprocess.run([str(Path(resolved["engine"]) / "bin/codeql"), "database", "cleanup", str(database),
                    f"--cache-cleanup={mode}", f"--max-disk-cache={CACHE_MB}"], check=True)


def warm(resolved, database, overlay):
    engine = str(Path(resolved["warm"]) / "bin/codeql")
    # Ordinary .qlx plans cannot execute in overlay mode. Let CodeQL compile
    # from the standing pack's source against the overlay-prepared database.
    options = ["--cache-at-frontier", "--no-use-precompiled"] if overlay else ["--no-cache-at-frontier"]
    subprocess.run([engine, "database", "run-queries", str(database), resolved["pack"],
                    *options, "--threads=4", "--ram=6000", f"--max-disk-cache={CACHE_MB}"], check=True)
    cleanup(resolved, database, "overlay" if overlay else "trim")


def supports_overlay(resolved):
    # Read the actual extractor, rather than assuming all CLI languages support it.
    return any(line.startswith("overlay_support_version:") for line in Path(resolved["manifest"]).read_text().splitlines())


def implementation():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def base_key(inputs):
    return digest([inputs["base"], inputs["tools"], inputs["spec"], inputs["overlay"], inputs["lifecycle"]])


def shared_directory(root, name):
    common = Path(run("git", "rev-parse", "--path-format=absolute", "--git-common-dir", cwd=root))
    return common / "codeql" / name


def git_generation(root, name, spec, resolved, generation, head, base, overlay, working):
    shared = shared_directory(root, name)
    inputs = {"base": base, "lifecycle": implementation(), "overlay": overlay, "spec": spec, "tools": resolved}
    key = base_key(inputs)
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


def eval_generation(root, spec, generation, commit):
    if not spec.get("evalSources"):
        return
    driver_path = root / "packages/codeql/src/eval_tables.py"
    module = importlib.util.spec_from_file_location("codeql_eval_tables", driver_path)
    driver = importlib.util.module_from_spec(module)
    module.loader.exec_module(driver)
    # Overlay generations retain the exact extraction snapshot, including the
    # working edits. Ordinary generations evaluate the same archived commit.
    if spec["source"] == "git" and (generation / "source").is_dir():
        driver.generate(generation / "source", spec["evalSources"], generation / "eval")
        return
    with tempfile.TemporaryDirectory(prefix="eval-input.", dir=generation) as temporary:
        snapshot = Path(temporary) / "source"
        archive(root, commit, snapshot)
        driver.generate(snapshot, spec["evalSources"], generation / "eval")


def read_inputs(path):
    try:
        inputs = json.loads(path.read_text())
        base_key(inputs)  # Reject legacy or malformed stamps without complete inputs.
        return inputs
    except (OSError, ValueError, KeyError, TypeError):
        return None


def optional_git(root, *args):
    result = subprocess.run(["git", *args], cwd=root, stdout=subprocess.PIPE, text=True)
    if result.returncode == 1:
        return None
    result.check_returncode()
    return result.stdout.strip()


def worktree_bases(root, name):
    # Missing origin/main is an error, even if a checkout has no usable HEAD.
    main = run("git", "rev-parse", "--verify", "origin/main^{commit}", cwd=root)
    records = subprocess.check_output(["git", "worktree", "list", "--porcelain", "-z"], cwd=root).split(b"\0")
    references = []
    for record in records:
        if not record.startswith(b"worktree "):
            continue
        worktree = Path(os.fsdecode(record[len(b"worktree "):]))
        if not worktree.is_dir():
            continue
        inputs = read_inputs(worktree / ".devenv/state/codeql" / name / "stamp")
        if not inputs:
            continue
        head = optional_git(worktree, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
        if head is None:  # An unborn checkout has no current base.
            continue
        base = optional_git(worktree, "merge-base", head, main)
        if base is None:  # An unrelated history has no current base.
            continue
        inputs["base"] = base
        references.append((worktree, base_key(inputs)))
    return references


def base_references(cached, references):
    return [str(worktree) for worktree, key in references if key == cached.name]


def prune(root, name, keep=None):
    # Caller holds this checkout's builder lock. Shared locks are always nested
    # inside it; never acquire another checkout's lock while holding base.lock.
    state = root / ".devenv/state/codeql" / name
    current = (state / "db").resolve() if (state / "db").is_symlink() else None
    for generation in sorted(state.glob("generation.*")):
        if (generation.is_dir() and not generation.is_symlink()
                and generation / "db" != current
                and time.time() - generation.stat().st_mtime >= ORPHAN_GRACE_SECONDS):
            shutil.rmtree(generation)
            print(f"{name}: removed orphan {generation.name}")
    shared = shared_directory(root, name)
    if not shared.is_dir():
        return
    with locked(shared / "base.lock"):
        references = worktree_bases(root, name)
        for cached in sorted(shared.iterdir()):
            if (cached.is_dir() and not cached.is_symlink() and cached.name != keep
                    and not base_references(cached, references)):
                shutil.rmtree(cached)
                print(f"{name}: removed shared base {cached.name}")


def disk_bytes(path):
    # du counts allocated blocks without following the engine's store symlink.
    return int(run("du", "-s", "--block-size=1", str(path)).split()[0]) if path.exists() else 0


def status(root, specs):
    checkout_total = shared_total = 0
    for name in sorted(specs):
        state = root / ".devenv/state/codeql" / name
        with locked(state / "lock"):
            database = state / "db"
            generation = database.resolve().parent.name if database.is_symlink() else "none"
            stamp = state / "stamp"
            age = f"{max(0, int(time.time() - stamp.stat().st_mtime))}s" if stamp.exists() else "unknown"
            size = disk_bytes(state)
            checkout_total += size
            print(f"database {name} generation={generation} stamp-age={age} size={size}B")
            eval_status = database.resolve().parent / "eval/status.json"
            if database.is_symlink() and eval_status.is_file():
                for source in json.loads(eval_status.read_text()):
                    print(f'eval {name} source={source["source"]} status={source["status"]} '
                          f'wall={source["wallSeconds"]:.3f}s peak={source["peakMb"]:.1f}MB rows={source["rowCounts"]}')
            shared = shared_directory(root, name)
            if not shared.is_dir():
                continue
            with locked(shared / "base.lock"):
                references = worktree_bases(root, name)
                for cached in sorted(shared.iterdir()):
                    if cached.is_dir() and not cached.is_symlink():
                        size = disk_bytes(cached)
                        shared_total += size
                        refs = json.dumps(base_references(cached, references))
                        print(f"base {name} key={cached.name} size={size}B worktrees={refs}")
    print(f"total checkout={checkout_total}B shared={shared_total}B combined={checkout_total + shared_total}B")


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
        if action == "gc":
            prune(root, name)
            return
        attribute, resolved = tools(root, spec)
        # Realize the manifest before inspecting capabilities; all tool paths
        # participate in both the worktree stamp and shared-base key.
        subprocess.run(["nix", "build", "--no-link", attribute + ".engine", attribute + ".createDatabase"]
                       + ([attribute + ".warmEngine"] if spec["source"] == "git" else []), cwd=root, check=True)
        inputs = {"spec": spec, "tools": resolved, "lifecycle": implementation()}
        head = base = None
        overlay = False
        if spec["source"] == "git":
            head = run("git", "rev-parse", "HEAD", cwd=root)
            base = run("git", "merge-base", head, "origin/main", cwd=root)
            overlay = supports_overlay(resolved)
            inputs.update(head=head, base=base, overlay=overlay)
            if overlay:
                inputs["working"] = content_stamp(root, changes(root, base, spec["extensions"]))
        if spec.get("evalSources"):
            inputs["eval"] = {
                "commit": head or run("git", "rev-parse", "HEAD", cwd=root),
                "driver": hashlib.sha256((root / "packages/codeql/src/eval_tables.py").read_bytes()).hexdigest(),
                "sources": spec["evalSources"],
            }
        stamp = json.dumps(inputs, sort_keys=True, separators=(",", ":")) + "\n"
        if action == "up" and old and (state / "stamp").exists() and (state / "stamp").read_text() == stamp:
            prune(root, name, base_key(inputs) if spec["source"] == "git" else None)
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
            cleanup(resolved, generation / "db")
            if spec.get("evalSources"):
                eval_generation(root, spec, generation, inputs["eval"]["commit"])
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
        prune(root, name, base_key(inputs) if spec["source"] == "git" else None)
        print(f"{name}: published {database.resolve()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["up", "refresh", "down", "gc", "status", "hook", "refresh-existing"])
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    root = Path(run("git", "rev-parse", "--show-toplevel"))
    specs = json.loads((root / "dev/codeql-databases.json").read_text())
    if args.action == "status":
        status(root, specs)
    elif args.action == "gc":
        for name in sorted(specs):
            lifecycle(root, name, specs[name], "gc")
    elif args.action == "hook":
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
