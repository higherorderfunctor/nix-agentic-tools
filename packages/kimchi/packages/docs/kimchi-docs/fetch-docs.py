#!/usr/bin/env python3

import argparse
import base64
import hashlib
import os
import re
import stat
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


BASE_URL = "https://docs.kimchi.dev"
ROOT_INDEX_URL = f"{BASE_URL}/llms.txt"
MARKDOWN_LINK = re.compile(r"\[[^]]*\]\(([^)\s]+)\)")
SAFE_PATH = re.compile(r"/[A-Za-z0-9._/-]+")


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, new_url):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


OPENER = urllib.request.build_opener(RejectRedirects)


def validate_url(url: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "docs.kimchi.dev"
        or parsed.query
        or parsed.fragment
        or not SAFE_PATH.fullmatch(parsed.path)
    ):
        raise ValueError(f"invalid documentation URL: {url}")

    segments = parsed.path.split("/")[1:]
    if any(segment in {"", ".", ".."} for segment in segments):
        raise ValueError(f"invalid documentation path: {parsed.path}")

    disallowed_segments = {"api-next", "cdn-cgi", "edit", "suggested-edits"}
    if any(segment in disallowed_segments for segment in segments) or parsed.path in {
        "/login",
        "/logout",
    }:
        raise ValueError(f"robots.txt disallows documentation path: {parsed.path}")

    if parsed.path != "/llms.txt" and not parsed.path.startswith("/docs/"):
        raise ValueError(f"documentation URL is outside the published index tree: {url}")
    return parsed


def fetch(url: str) -> bytes:
    validate_url(url)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "text/markdown, text/plain",
            "User-Agent": "nix-agentic-tools-kimchi-docs/1",
        },
    )
    with OPENER.open(request, timeout=60) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected HTTP status {response.status} for {url}")
        body = response.read()
    if not body:
        raise RuntimeError(f"empty response for {url}")
    body.decode("utf-8")
    return body


def classify_link(url: str) -> tuple[str, str]:
    parsed = validate_url(url)
    if parsed.path == "/llms.txt" or parsed.path.endswith("/llms.txt"):
        return "index", url
    if parsed.path.endswith(".md"):
        return "page", url
    if "." not in parsed.path.rsplit("/", 1)[-1]:
        return "page", f"{url}.md"
    raise ValueError(f"unsupported documentation link: {url}")


def links_from(index_url: str, body: bytes) -> list[tuple[str, str]]:
    links = []
    for target in MARKDOWN_LINK.findall(body.decode("utf-8")):
        resolved = urllib.parse.urljoin(index_url, target)
        parsed = urllib.parse.urlsplit(resolved)
        if parsed.netloc == "docs.kimchi.dev":
            links.append(classify_link(resolved))
    if not links:
        raise RuntimeError(f"documentation index contains no same-site links: {index_url}")
    return sorted(set(links))


def output_path(output: Path, url: str) -> Path:
    relative = validate_url(url).path.removeprefix("/")
    return output / relative


def write_fetched(output: Path, url: str, body: bytes) -> None:
    destination = output_path(output, url)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(body)


def write_attribution(output: Path, snapshot_date: str) -> None:
    (output / "ATTRIBUTION").write_text(
        """Kimchi documentation snapshot

Copyright the Kimchi documentation authors.
Source: https://docs.kimchi.dev/
Snapshot date: {snapshot_date}

Fetched from upstream's published Markdown indexes and page endpoints. The
documentation is not licensed by this repository; all rights remain with its
upstream owners.
""".format(snapshot_date=snapshot_date),
        encoding="utf-8",
    )


def normalize_metadata(output: Path) -> None:
    paths = sorted(output.rglob("*"), key=lambda path: path.as_posix())
    files = [path for path in paths if path.is_file()]
    directories = [path for path in paths if path.is_dir()]
    for path in files:
        path.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
        os.utime(path, (1, 1), follow_symlinks=False)
    for path in reversed([output, *directories]):
        path.chmod(
            stat.S_IRUSR
            | stat.S_IWUSR
            | stat.S_IXUSR
            | stat.S_IRGRP
            | stat.S_IXGRP
            | stat.S_IROTH
            | stat.S_IXOTH
        )
        os.utime(path, (1, 1), follow_symlinks=False)


def content_hash(output: Path) -> str:
    digest = hashlib.sha256()
    files = sorted(
        (path for path in output.rglob("*") if path.is_file()),
        key=lambda path: path.as_posix(),
    )
    for path in files:
        relative = path.relative_to(output).as_posix().encode()
        body = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(body).to_bytes(8, "big"))
        digest.update(body)
    return "sha256-" + base64.b64encode(digest.digest()).decode()


def snapshot(output: Path, snapshot_date: str) -> tuple[int, int, str]:
    if output.exists():
        raise FileExistsError(f"output path already exists: {output}")
    output.mkdir(parents=True)

    pending_indexes = {ROOT_INDEX_URL}
    fetched_indexes: set[str] = set()
    page_urls: set[str] = set()

    while pending_indexes:
        index_url = sorted(pending_indexes)[0]
        pending_indexes.remove(index_url)
        body = fetch(index_url)
        write_fetched(output, index_url, body)
        fetched_indexes.add(index_url)

        for kind, url in links_from(index_url, body):
            if kind == "index" and url not in fetched_indexes:
                pending_indexes.add(url)
            elif kind == "page":
                page_urls.add(url)

    substantive_index = f"{BASE_URL}/docs/llms.txt"
    if substantive_index not in fetched_indexes:
        raise RuntimeError(f"required documentation index was not discovered: {substantive_index}")
    if not page_urls:
        raise RuntimeError("documentation indexes contain no pages")

    for page_url in sorted(page_urls):
        write_fetched(output, page_url, fetch(page_url))

    upstream_hash = content_hash(output)
    write_attribution(output, snapshot_date)
    normalize_metadata(output)
    return len(fetched_indexes), len(page_urls), upstream_hash


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("snapshot_date")
    parser.add_argument("content_hash_file", type=Path)
    args = parser.parse_args()
    indexes, pages, upstream_hash = snapshot(args.output, args.snapshot_date)
    args.content_hash_file.write_text(upstream_hash + "\n", encoding="utf-8")
    print(f"fetched {indexes} indexes and {pages} pages")


if __name__ == "__main__":
    main()
