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

HASHES_FILE="overlays/sources/hashes.json"

# Start fresh — hashes.json is pure output, rebuilt from scratch.
# Stale entries from removed packages are automatically cleaned.
if [ $# -eq 0 ]; then
	echo '{}' >"$HASHES_FILE"
fi

# Dep attribute → hashes.json field name mapping
declare -A DEP_ATTRS=(
	[pnpmDeps]=pnpmDepsHash
	[goModules]=vendorHash
	[cargoDeps]=cargoHash
)

write_hash() {
	local pkg="$1" field="$2" hash="$3"
	echo "UPDATE: $pkg.$field → $hash"
	local tmp
	tmp=$(mktemp)
	jq --arg pkg "$pkg" --arg field "$field" --arg hash "$hash" \
		'.[$pkg][$field] = $hash' "$HASHES_FILE" >"$tmp"
	mv "$tmp" "$HASHES_FILE"
	((updated++)) || true
}

# Extract hash from build output (grep may return no match — || true prevents set -e abort)
extract_got_hash() {
	grep "got:" <<<"$1" | head -1 | awk '{print $2}' || true
}

extract_drv_name() {
	grep "hash mismatch" <<<"$1" | head -1 |
		sed -e "s/.*\/nix\/store\/[a-z0-9]*-//" -e "s/\.drv.*//" -e "s/'//g" || true
}

detect_hash_field() {
	local drv_name="$1"
	if echo "$drv_name" | grep -qi "npm-deps"; then
		echo "npmDepsHash"
		return
	fi
	if echo "$drv_name" | grep -qi "pnpm-deps"; then
		echo "pnpmDepsHash"
		return
	fi
	if echo "$drv_name" | grep -qi "vendor\|go-modules"; then
		echo "vendorHash"
		return
	fi
	if echo "$drv_name" | grep -qi "cargo"; then
		echo "cargoHash"
		return
	fi
	# Platform-specific hashes are now handled by nvfetcher per-platform
	# entries (e.g., copilot-cli-linux-x64, kiro-cli-darwin-arm64).
	# No platform detection needed in the script.
	echo "srcHash"
}

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

		if ! nix eval ".#${pkg}.${dep_attr}" --apply 'x: true' >/dev/null 2>&1; then
			continue
		fi

		found_dep=true

		# Build just the dep derivation (fast — no compilation)
		output=$(nix build ".#${pkg}.${dep_attr}" --no-link 2>&1) && continue

		got_hash=$(extract_got_hash "$output")
		if [ -z "$got_hash" ]; then
			echo "FAIL: $pkg.$dep_attr (build error, not hash mismatch)"
			echo "$output" | tail -3
			continue
		fi

		write_hash "$pkg" "$hash_field" "$got_hash"
	done

	if $found_dep; then continue; fi

	# No dep attr found — try full build (npm packages, pre-built binaries)
	output=$(nix build ".#${pkg}" --no-link 2>&1) && continue

	got_hash=$(extract_got_hash "$output")
	if [ -z "$got_hash" ]; then
		# Not a hash mismatch — skip (could be a Nix throw for missing
		# platform hash, or some other build error). These need manual
		# attention or a different update mechanism.
		continue
	fi

	drv_name=$(extract_drv_name "$output")
	hash_field=$(detect_hash_field "$drv_name")

	write_hash "$pkg" "$hash_field" "$got_hash"

	# Second pass: check for a second hash (e.g., srcHash then npmDepsHash)
	output2=$(nix build ".#${pkg}" --no-link 2>&1) || true
	got_hash2=$(extract_got_hash "$output2")
	if [ -n "$got_hash2" ] && [ "$got_hash2" != "$got_hash" ]; then
		drv_name2=$(extract_drv_name "$output2")
		hash_field2=$(detect_hash_field "$drv_name2")
		write_hash "$pkg" "$hash_field2" "$got_hash2"
	fi
done

if [ "$updated" -gt 0 ]; then
	echo ""
	echo "Updated $updated hash(es) in $HASHES_FILE"
	echo "Run 'nix flake check' to verify."
else
	echo "All hashes up to date."
fi
