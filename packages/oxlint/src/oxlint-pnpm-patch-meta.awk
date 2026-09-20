# Add a name-only pnpm patch entry and tag every resolved peer variant.
# Package versions come from upstream's lock; only context application decides
# whether the committed patch remains compatible. pnpm 11 rejects patch failures.
# Required variables: pkg, val (path/hash), q (key quote), tag (non-empty for
# a lock file), ph (patch hash).

BEGIN {
    depKey = q pkg q ":"
    snapPfx = q pkg "@"
    token = "(patch_hash=" ph ")"
}

function trim(s) {
    sub(/^[ \t]+/, "", s)
    return s
}

function stampReference(s) {
    if (s ~ /\(/) sub(/\(/, token "(", s)
    else s = s token
    return s
}

/^overrides:[ \t]*$/ {
    seenOverrides = 1
    print
    next
}

# Upstream taking ownership of patchedDependencies is the case this must not
# paper over. Emitting a second top-level key of the same name either fails
# YAML parsing or, worse, loses to the last one — which drops our entry and
# ships an UNPATCHED dependency with no error anywhere. Must precede the insert
# rule below so that key is counted rather than treated as the anchor.
/^patchedDependencies:[ \t]*$/ {
    nExisting++
    print
    next
}

# pnpm writes the block immediately before the first top-level key following
# `overrides:`. Anchoring there reproduces its own placement without caring
# which key that happens to be.
seenOverrides && nBlock == 0 && /^[A-Za-z]/ {
    print "patchedDependencies:"
    print "  " q pkg q ": " val
    print ""
    nBlock = 1
    section = $0
    print
    next
}

{ t = trim($0) }

# A catalog also names the package, but only importers carry resolved versions.
/^[A-Za-z][A-Za-z]*:[ \t]*$/ { section = $0 }

# An importer's `version:` line names the resolved peer set but NOT the
# package, so it is identifiable only from the dependency key above it.
tag != "" && section == "importers:" && t == depKey {
    inDep = 1
    nDep++
    print
    next
}

tag != "" && inDep && t ~ /^version: [0-9]+\.[0-9]+\.[0-9]+/ {
    $0 = stampReference($0)
    nImp++
    inDep = 0
    print
    next
}

tag != "" && inDep && index(t, "specifier:") == 1 {
    print
    next
}

tag != "" && inDep { inDep = 0 }

# Other snapshots can depend on the patched package too, through either
# dependencies or optionalDependencies. Their values are resolved references.
tag != "" && section == "snapshots:" && index(t, depKey " ") == 1 {
    $0 = stampReference($0)
    nRef++
    print
    next
}

# Snapshot keys name the package inline. The bare `@<ver>:` entry under
# `packages:` carries no peer suffix and pnpm does not patch-tag it.
tag != "" && section == "snapshots:" && index(t, snapPfx) == 1 {
    if ($0 ~ /\(/) sub(/\(/, token "(", $0)
    else sub(q ":", token q ":", $0)
    nSnap++
    print
    next
}

{ print }

END {
    if (nExisting > 0) {
        print "oxlint: FILE already declares a top-level patchedDependencies — upstream took ownership of it. Merge our entry into theirs by hand; a second key would be dropped silently." > "/dev/stderr"
        exit 1
    }
    if (!seenOverrides) {
        print "oxlint: no top-level `overrides:` key — nothing to anchor patchedDependencies against" > "/dev/stderr"
        exit 1
    }
    if (nBlock != 1) {
        print "oxlint: `overrides:` is the last top-level key — no following key to place patchedDependencies before" > "/dev/stderr"
        exit 1
    }
    if (tag != "" && (nImp + nRef == 0 || nImp != nDep)) {
        print "oxlint: not every importer of " pkg " was patched — inspect the lockfile" > "/dev/stderr"
        exit 1
    }
    if (tag != "" && nSnap == 0) {
        print "oxlint: no snapshot entry for " pkg " — inspect the lockfile" > "/dev/stderr"
        exit 1
    }
    if (tag != "") {
        print "oxlint: patch_hash stamped on " nImp " importer + " nRef " transitive reference + " nSnap " snapshot entries" > "/dev/stderr"
    }
}
