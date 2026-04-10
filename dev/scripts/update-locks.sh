#!/usr/bin/env bash
# Regenerate npm lockfiles in overlays/locks/ from overlay package sources.
#
# Auto-discovers: probes each flake package for a package.json in its
# source. If found, generates a lockfile. Rebuilds from scratch when
# run without args — stale lockfiles from removed packages are cleaned.
#
# Usage: dev/scripts/update-locks.sh [package ...]
#   No args → all packages (rebuild from scratch). With args → only those.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

LOCKS_DIR="overlays/locks"

if [ $# -gt 0 ]; then
	packages=("$@")
else
	# Rebuild from scratch — remove all existing lockfiles, discover fresh
	rm -f "$LOCKS_DIR"/*-package-lock.json
	mapfile -t packages < <(
		nix eval .#packages.x86_64-linux --apply 'builtins.attrNames' --json 2>/dev/null |
			jq -r '.[]' |
			grep -vE "^(instructions-|docs)"
	)
fi

echo "Checking ${#packages[@]} packages for npm lockfiles..."

updated=0
for pkg in "${packages[@]}"; do
	# Get the package source path
	src=$(nix eval ".#${pkg}.src" --raw 2>/dev/null) || continue

	# Find package.json — at root or one level deep
	pkg_json=""
	if [ -f "$src/package.json" ]; then
		pkg_json="$src/package.json"
	else
		for candidate in "$src"/*/package.json; do
			if [ -f "$candidate" ]; then
				pkg_json="$candidate"
				break
			fi
		done
	fi

	[ -z "$pkg_json" ] && continue

	pkg_dir=$(dirname "$pkg_json")
	lockfile="$LOCKS_DIR/${pkg}-package-lock.json"

	# Generate lockfile in a temp dir
	tmp=$(mktemp -d)
	cp "$pkg_dir/package.json" "$tmp/"
	[ -f "$pkg_dir/tsconfig.json" ] && cp "$pkg_dir/tsconfig.json" "$tmp/"

	if npm install --package-lock-only --prefix "$tmp" --ignore-scripts >/dev/null 2>&1; then
		cp "$tmp/package-lock.json" "$lockfile"
		echo "LOCK: $pkg → $lockfile"
		((updated++)) || true
	fi

	rm -rf "$tmp"
done

if [ "$updated" -gt 0 ]; then
	echo ""
	echo "Generated $updated lockfile(s) in $LOCKS_DIR"
else
	echo "No npm lockfiles needed."
fi
