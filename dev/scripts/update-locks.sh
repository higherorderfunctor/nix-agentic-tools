#!/usr/bin/env bash
# Regenerate npm lockfiles in overlays/sources/locks/ from overlay package sources.
#
# Auto-discovers: probes each flake package for an npmDeps attribute
# (only packages using buildNpmPackage have this). If found and the
# source contains a package.json, generates a lockfile. When a lockfile
# changes, resets the corresponding npmDepsHash in hashes.json to the
# dummy hash so update-hashes.sh recomputes it.
#
# Prunes lockfiles for packages that no longer use npm, but only
# lockfiles the script manages (packages with npmDeps attr).
#
# Usage: dev/scripts/update-locks.sh [package ...]
#   No args → all packages. With args → only those.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

LOCKS_DIR="overlays/sources/locks"
HASHES_FILE="overlays/sources/hashes.json"
DUMMY_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

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

declare -A probed_npm

for pkg in "${packages[@]}"; do
	# Only process packages that actually use buildNpmPackage (have npmDeps attr)
	if ! nix eval ".#${pkg}.npmDeps" --apply 'x: true' >/dev/null 2>&1; then
		continue
	fi
	probed_npm[$pkg]=1

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
		# Only update if the lockfile actually changed
		if [ ! -f "$lockfile" ] || ! diff -q "$tmp/package-lock.json" "$lockfile" >/dev/null 2>&1; then
			cp "$tmp/package-lock.json" "$lockfile"
			echo "LOCK: $pkg → $lockfile"
			((updated++)) || true

			# Reset npmDepsHash so update-hashes.sh recomputes it
			if [ -f "$HASHES_FILE" ]; then
				hash_tmp=$(mktemp)
				jq --arg pkg "$pkg" --arg hash "$DUMMY_HASH" \
					'.[$pkg].npmDepsHash = $hash' "$HASHES_FILE" >"$hash_tmp"
				mv "$hash_tmp" "$HASHES_FILE"
				echo "  → reset $pkg.npmDepsHash (lockfile changed)"
			fi
		fi
	fi

	rm -rf "$tmp"
done

# Prune lockfiles only for packages the script probed (has npmDeps attr)
# but no longer need a lockfile. Leave not probed packages alone — their
# lockfiles are managed elsewhere (e.g., claude-code).
if [ $# -eq 0 ]; then
	for lockfile in "$LOCKS_DIR"/*-package-lock.json; do
		[ -f "$lockfile" ] || continue
		name=$(basename "$lockfile" -package-lock.json)
		if [ -n "${probed_npm[$name]+x}" ] && [ -z "${has_lockfile[$name]+x}" ]; then
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
