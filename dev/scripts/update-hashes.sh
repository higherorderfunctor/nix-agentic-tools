#!/usr/bin/env bash
# Auto-discover and compute dep hashes for overlay packages.
#
# Walks all flake packages. If a build fails with a hash mismatch
# ("got: sha256-..."), captures the correct hash and writes it to
# overlays/hashes.json. No hardcoded package list — new packages
# are discovered automatically via the hashDefaults dummy pattern.
#
# Usage: dev/scripts/update-hashes.sh [package ...]
#   No args → all packages. With args → only those packages.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

HASHES_FILE="overlays/hashes.json"
DUMMY_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# Get package list
if [ $# -gt 0 ]; then
	packages=("$@")
else
	# All flake packages except instruction derivations
	mapfile -t packages < <(
		nix eval .#packages.x86_64-linux --apply '
      pkgs: builtins.filter (n:
        !(builtins.hasPrefix "instructions-" n)
      ) (builtins.attrNames pkgs)
    ' --json 2>/dev/null | jq -r '.[]'
	)
fi

echo "Checking ${#packages[@]} packages for hash mismatches..."

updated=0
for pkg in "${packages[@]}"; do
	# Try building. Capture stderr for hash mismatch detection.
	output=$(nix build ".#${pkg}" --no-link 2>&1) && continue

	# Check for hash mismatch
	got_hash=$(echo "$output" | grep "got:" | head -1 | awk '{print $2}')
	if [ -z "$got_hash" ]; then
		echo "FAIL: $pkg (not a hash mismatch)"
		echo "$output" | tail -5
		continue
	fi

	# Determine which hash field by checking the derivation name in the error
	drv_name=$(echo "$output" | grep -oP '/nix/store/[a-z0-9]+-\K[^.]+(?=\.drv)' | head -1)

	hash_field=""
	if echo "$drv_name" | grep -qi "pnpm-deps"; then
		hash_field="pnpmDepsHash"
	elif echo "$drv_name" | grep -qi "vendor\|go-modules"; then
		hash_field="vendorHash"
	elif echo "$drv_name" | grep -qi "npm-deps"; then
		hash_field="npmDepsHash"
	elif echo "$drv_name" | grep -qi "cargo-deps\|crate"; then
		hash_field="cargoHash"
	else
		# Could be srcHash or a platform-specific hash — try to detect
		specified=$(echo "$output" | grep "specified:" | head -1 | awk '{print $2}')
		if [ "$specified" = "$DUMMY_HASH" ]; then
			# It's using our dummy — but we can't determine the field name
			# from the drv name alone. Fall back to checking which field in
			# hashes.json has the dummy for this package.
			for field in srcHash pnpmDepsHash vendorHash npmDepsHash cargoHash; do
				current=$(jq -r ".\"${pkg}\".\"${field}\" // empty" "$HASHES_FILE" 2>/dev/null)
				if [ "$current" = "$DUMMY_HASH" ] || [ -z "$current" ]; then
					hash_field="$field"
					break
				fi
			done
		fi
		if [ -z "$hash_field" ]; then
			echo "UNKNOWN: $pkg → got $got_hash (drv: $drv_name)"
			echo "  Cannot determine hash field. Add manually to $HASHES_FILE"
			continue
		fi
	fi

	echo "UPDATE: $pkg.$hash_field → $got_hash"

	# Write to hashes.json
	tmp=$(mktemp)
	jq --arg pkg "$pkg" --arg field "$hash_field" --arg hash "$got_hash" \
		'.[$pkg][$field] = $hash' "$HASHES_FILE" >"$tmp"
	mv "$tmp" "$HASHES_FILE"

	((updated++)) || true

	# Rebuild to check if there's a second hash needed (e.g., srcHash then npmDepsHash)
	output2=$(nix build ".#${pkg}" --no-link 2>&1) || true
	got_hash2=$(echo "$output2" | grep "got:" | head -1 | awk '{print $2}')
	if [ -n "$got_hash2" ] && [ "$got_hash2" != "$got_hash" ]; then
		drv_name2=$(echo "$output2" | grep -oP '/nix/store/[a-z0-9]+-\K[^.]+(?=\.drv)' | head -1)
		hash_field2=""
		if echo "$drv_name2" | grep -qi "npm-deps"; then
			hash_field2="npmDepsHash"
		elif echo "$drv_name2" | grep -qi "pnpm-deps"; then
			hash_field2="pnpmDepsHash"
		elif echo "$drv_name2" | grep -qi "vendor\|go-modules"; then
			hash_field2="vendorHash"
		fi
		if [ -n "$hash_field2" ]; then
			echo "UPDATE: $pkg.$hash_field2 → $got_hash2"
			tmp=$(mktemp)
			jq --arg pkg "$pkg" --arg field "$hash_field2" --arg hash "$got_hash2" \
				'.[$pkg][$field] = $hash' "$HASHES_FILE" >"$tmp"
			mv "$tmp" "$HASHES_FILE"
			((updated++)) || true
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
