"""Pinned Markdown snapshots for explicit pages and published Markdown indexes."""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

MARKDOWN_LINK = re.compile(r"\[[^]]*\]\(([^)\s]+)\)")


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, new_url):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def fetch(url):
    request = urllib.request.Request(url, headers={
        "Accept": "text/markdown, text/plain",
        "User-Agent": "nix-agentic-tools-docs/1",
    })
    with urllib.request.build_opener(RejectRedirects).open(request, timeout=60) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected HTTP status {response.status} for {url}")
        body = response.read()
    if not body:
        raise ValueError(f"empty response for {url}")
    body.decode("utf-8")
    return body


def validate_url(url, index):
    parsed = urllib.parse.urlsplit(url)
    origin = urllib.parse.urlsplit(index["url"])
    if (parsed.scheme != "https" or parsed.netloc != origin.netloc
            or parsed.query or parsed.fragment
            or not re.fullmatch(r"/[A-Za-z0-9._/-]+", parsed.path)):
        raise ValueError(f"invalid documentation URL: {url}")
    segments = parsed.path.split("/")[1:]
    if any(segment in {"", ".", ".."} for segment in segments):
        raise ValueError(f"invalid documentation path: {parsed.path}")
    if (parsed.path in index["deniedPaths"]
            or any(segment in index["deniedSegments"] for segment in segments)):
        raise ValueError(f"robots.txt disallows documentation path: {parsed.path}")
    if (parsed.path not in index["allowedPaths"]
            and not any(parsed.path.startswith(prefix) for prefix in index["allowedPrefixes"])):
        raise ValueError(f"documentation URL is outside the published index tree: {url}")
    return parsed


def write_page(output, relative, body, replace=False):
    path = PurePosixPath(relative)
    # Explicit mappings must not escape their snapshot (e.g. ../models.md).
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError(f"invalid snapshot path: {relative}")
    destination = output / path
    if destination.exists():
        if not replace:
            raise ValueError(f"duplicate snapshot path: {relative}")
        destination.unlink()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(body)


def content_hash(output):
    digest = hashlib.sha256()
    for path in sorted((path for path in output.rglob("*") if path.is_file()), key=lambda path: path.as_posix()):
        relative = path.relative_to(output).as_posix().encode()
        body = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(body).to_bytes(8, "big"))
        digest.update(body)
    return "sha256-" + base64.b64encode(digest.digest()).decode()


def normalize_metadata(output):
    paths = sorted(output.rglob("*"), key=lambda path: path.as_posix())
    for path in paths:
        if path.is_file():
            path.chmod(0o444)
            os.utime(path, (1, 1), follow_symlinks=False)
    for path in reversed([output, *(path for path in paths if path.is_dir())]):
        path.chmod(0o755)
        os.utime(path, (1, 1), follow_symlinks=False)


def write_generated(config, output, snapshot_date, replace=False):
    for path, template in config.get("generated", {}).items():
        write_page(output, path, template.replace("{snapshot_date}", snapshot_date).encode(), replace)


def snapshot(config, output, snapshot_date, fetch_page=fetch):
    output.mkdir(parents=True)
    index = config.get("index")
    indexes, pages = set(), set()
    if index:
        pending = {config["index"]["url"]}
        origin = urllib.parse.urlsplit(config["index"]["url"]).netloc
        while pending:
            url = min(pending)
            pending.remove(url)
            parsed = validate_url(url, index)
            body = fetch_page(url)
            write_page(output, parsed.path.removeprefix("/"), body)
            indexes.add(url)
            links = set()
            for target in MARKDOWN_LINK.findall(body.decode("utf-8")):
                resolved = urllib.parse.urljoin(url, target)
                if urllib.parse.urlsplit(resolved).netloc != origin:
                    continue
                parsed = validate_url(resolved, index)
                if parsed.path.endswith("/llms.txt"):
                    links.add(("index", resolved))
                elif parsed.path.endswith(".md"):
                    links.add(("page", resolved))
                elif "." not in parsed.path.rsplit("/", 1)[-1]:
                    links.add(("page", resolved + ".md"))
                else:
                    raise ValueError(f"unsupported documentation link: {resolved}")
            if not links:
                raise ValueError(f"documentation index contains no same-site links: {url}")
            pending.update(link for kind, link in links if kind == "index" and link not in indexes)
            pages.update(link for kind, link in links if kind == "page")
        for url in sorted(pages):
            parsed = validate_url(url, index)
            write_page(output, parsed.path.removeprefix("/"), fetch_page(url))
        missing = set(index["requiredIndexes"]) - indexes
        if missing:
            raise ValueError(f"required documentation indexes were not discovered: {sorted(missing)}")
        if not pages:
            raise ValueError("documentation indexes contain no pages")
    else:
        for source in config["sources"]:
            write_page(output, source["path"], fetch_page(source["url"]))
    # Owner-generated dated attribution is deliberately outside content identity.
    digest = content_hash(output)
    write_generated(config, output, snapshot_date)
    if config.get("validate"):
        subprocess.run([config["validate"], str(output)], check=True)
    normalize_metadata(output)
    return digest


def pin_fields(text):
    fields = {}
    for key in ("contentHash", "hash", "snapshotDate"):
        matches = re.findall(rf'^  {key} = "([^"\n]+)";$', text, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"expected exactly one recipe field: {key}")
        fields[key] = matches[0]
    return fields


def publish(pin, original, replacement):
    if pin.read_text(encoding="utf-8") != original:
        raise RuntimeError(f"documentation pin changed during update: {pin}")
    with tempfile.NamedTemporaryFile(dir=pin.parent, prefix=f".{pin.name}.", mode="w", delete=False) as staged:
        temporary = Path(staged.name)
        try:
            staged.write(replacement)
            staged.flush()
            temporary.chmod(pin.stat().st_mode & 0o777)
            temporary.replace(pin)
        finally:
            temporary.unlink(missing_ok=True)


def update(config, pin, nix, snapshot_date=None, fetch_page=fetch):
    original = pin.read_text(encoding="utf-8")
    fields = pin_fields(original)
    date = snapshot_date or datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    with tempfile.TemporaryDirectory(prefix="web-docs-") as work:
        output = Path(work) / "snapshot"
        # Compare generated bytes at the existing date: a changed attribution
        # template must repair its output hash without daily capture-date churn.
        digest = snapshot(config, output, fields["snapshotDate"], fetch_page)
        if digest != fields["contentHash"]:
            write_generated(config, output, date, replace=True)
            normalize_metadata(output)
        else:
            date = fields["snapshotDate"]
        output_hash = subprocess.check_output([nix, "--extra-experimental-features", "nix-command", "hash", "path", "--type", "sha256", str(output)], text=True).strip()
        if digest == fields["contentHash"] and output_hash == fields["hash"]:
            print(f"{config['name']}: documentation is unchanged")
            return False
        updated = original
        for key, value in (("contentHash", digest), ("hash", output_hash), ("snapshotDate", date)):
            updated = re.sub(rf'^  {key} = "[^"\n]+";$', f'  {key} = "{value}";', updated, count=1, flags=re.MULTILINE)
        publish(pin, original, updated)
    print(f"{config['name']}: {fields['snapshotDate']} -> {date}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["snapshot", "update"])
    parser.add_argument("config", type=Path)
    parser.add_argument("path", type=Path)
    parser.add_argument("date_or_nix")
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if args.mode == "update":
        update(config, args.path, args.date_or_nix)
    else:
        digest = snapshot(config, args.path, args.date_or_nix)
        if digest != config["contentHash"]:
            raise ValueError(f"{config['name']}: content hash mismatch")


if __name__ == "__main__":
    main()
