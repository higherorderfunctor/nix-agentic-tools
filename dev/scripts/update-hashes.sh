#!/usr/bin/env bash
# Auto-discover and compute dep hashes for overlay packages.
#
# Probes each flake package for dep derivation attributes (.pnpmDeps,
# .goModules, .cargoDeps) and builds them to discover the correct hash.
# No hardcoded package list. hashes.json is pure OUTPUT — never read
# for discovery. The overlay's hashDefaults provide dummies for missing
# entries, so new packages are discovered automatically.
#
# Usage: dev/scripts/update-hashes.sh [package ...]
#   No args → all packages. With args → only those packages.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

HASHES_FILE="overlays/hashes.json"

# Dep attribute → hashes.json field name mapping
# Order matters: try specific dep attrs first, fall back to full build
declare -A DEP_ATTRS=(
	[pnpmDeps]=pnpmDepsHash
	[goModules]=vendorHash
	[cargoDeps]=cargoHash
)

# Get package list
if [ $# -gt 0 ]; then
	packages=("$@")
else
	mapfile -t packages < <(
		nix eval .#packages.x86_64-linux --apply 'builtins.attrNames' --json 2>/dev/null |
			jq -r '.[]' |
			grep -vE "^(instructions-|docs)"
	)
fi

echo "Checking ${#packages[@]} packages for dep hashes..."

updated=0
for pkg in "${packages[@]}"; do
	found_dep=false

	# Probe for known dep derivation attributes
	for dep_attr in "${!DEP_ATTRS[@]}"; do
		hash_field="${DEP_ATTRS[$dep_attr]}"

		# Check if the attribute exists on the package
		if ! nix eval ".#${pkg}.${dep_attr}" --apply 'x: true' >/dev/null 2>&1; then
			continue
		fi

		found_dep=true

		# Build just the dep derivation (fast — no compilation)
		output=$(nix build ".#${pkg}.${dep_attr}" --no-link 2>&1) && continue

		got_hash=$(echo "$output" | grep "got:" | head -1 | awk '{print $2}')
		if [ -z "$got_hash" ]; then
			echo "FAIL: $pkg.$dep_attr (build error, not hash mismatch)"
			echo "$output" | tail -3
			continue
		fi

		echo "UPDATE: $pkg.$hash_field → $got_hash"
		tmp=$(mktemp)
		jq --arg pkg "$pkg" --arg field "$hash_field" --arg hash "$got_hash" \
			'.[$pkg][$field] = $hash' "$HASHES_FILE" >"$tmp"
		mv "$tmp" "$HASHES_FILE"
		((updated++)) || true
	done

	# For npm packages: no standalone dep attr — buildNpmPackage embeds
	# the FOD internally. Fall back to full build to catch npmDepsHash.
	if ! $found_dep; then
		output=$(nix build ".#${pkg}" --no-link 2>&1) && continue

		got_hash=$(echo "$output" | grep "got:" | head -1 | awk '{print $2}')
		if [ -z "$got_hash" ]; then
			# Not a hash mismatch — some other build error or no hash needed
			continue
		fi

		# Detect hash field from the failing derivation name
		drv_name=$(echo "$output" | grep "hash mismatch" | head -1 |
			sed -e "s/.*\/nix\/store\/[a-z0-9]*-//" -e "s/\.drv.*//" -e "s/'//g")

		hash_field=""
		if echo "$drv_name" | grep -qi "npm-deps"; then
			hash_field="npmDepsHash"
		elif echo "$drv_name" | grep -qi "pnpm-deps"; then
			hash_field="pnpmDepsHash"
		elif echo "$drv_name" | grep -qi "vendor\|go-modules"; then
			hash_field="vendorHash"
		elif echo "$drv_name" | grep -qi "cargo"; then
			hash_field="cargoHash"
		else
			hash_field="srcHash"
		fi

		echo "UPDATE: $pkg.$hash_field → $got_hash"
		tmp=$(mktemp)
		jq --arg pkg "$pkg" --arg field "$hash_field" --arg hash "$got_hash" \
			'.[$pkg][$field] = $hash' "$HASHES_FILE" >"$tmp"
		mv "$tmp" "$HASHES_FILE"
		((updated++)) || true

		# Check for a second hash (e.g., srcHash then npmDepsHash)
		output2=$(nix build ".#${pkg}" --no-link 2>&1) || true
		got_hash2=$(echo "$output2" | grep "got:" | head -1 | awk '{print $2}')
		if [ -n "$got_hash2" ] && [ "$got_hash2" != "$got_hash" ]; then
			drv_name2=$(echo "$output2" | grep "hash mismatch" | head -1 |
				sed -e "s/.*\/nix\/store\/[a-z0-9]*-//" -e "s/\.drv.*//" -e "s/'//g")
			hash_field2=""
			if echo "$drv_name2" | grep -qi "npm-deps"; then hash_field2="npmDepsHash"; fi
			if echo "$drv_name2" | grep -qi "pnpm-deps"; then hash_field2="pnpmDepsHash"; fi
			if [ -n "$hash_field2" ]; then
				echo "UPDATE: $pkg.$hash_field2 → $got_hash2"
				tmp=$(mktemp)
				jq --arg pkg "$pkg" --arg field "$hash_field2" --arg hash "$got_hash2" \
					'.[$pkg][$field] = $hash' "$HASHES_FILE" >"$tmp"
				mv "$tmp" "$HASHES_FILE"
				((updated++)) || true
			fi
		fi
	fi
done

if [ "$updated" -gt 0 ]; then
	echo ""
	echo "Updated $updated hash(es) in $HASHES_FILE"
	echo "Run 'nix flake check' to verify."
else
	echo "All hashes up to date."
fi
