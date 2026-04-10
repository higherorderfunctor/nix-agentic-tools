#!/usr/bin/env bash
# Regenerate npm lockfiles in overlays/sources/locks/ from overlay package sources.
#
# Auto-discovers: probes each flake package for a package.json in its
# source. If found, generates a lockfile. Keeps existing lockfiles for
# unchanged packages (fast no-op). Prunes lockfiles for removed packages
# or packages that no longer need npm.
#
# Usage: dev/scripts/update-locks.sh [package ...]
#   No args → all packages. With args → only those.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

LOCKS_DIR="overlays/sources/locks"

if [ $# -gt 0 ]; then
	packages=("$@")
else
	system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
	mapfile -t packages < <(
		nix eval ".#packages.${system}" --apply 'builtins.attrNames' --json 2>/dev/null |
			jq -r '.[]' |
			grep -vE "^(instructions-|docs)"
	)
fi

echo "Checking ${#packages[@]} packages for npm lockfiles..."

updated=0
declare -A has_lockfile

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

	has_lockfile[$pkg]=1
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

# Prune lockfiles for packages removed or no longer needing npm
if [ $# -eq 0 ]; then
	for lockfile in "$LOCKS_DIR"/*-package-lock.json; do
		[ -f "$lockfile" ] || continue
		name=$(basename "$lockfile" -package-lock.json)
		if [ -z "${has_lockfile[$name]+x}" ]; then
			echo "PRUNE: $lockfile"
			rm -f "$lockfile"
		fi
	done
fi

if [ "$updated" -gt 0 ]; then
	echo ""
	echo "Generated $updated lockfile(s) in $LOCKS_DIR"
else
	echo "No npm lockfiles needed."
fi
