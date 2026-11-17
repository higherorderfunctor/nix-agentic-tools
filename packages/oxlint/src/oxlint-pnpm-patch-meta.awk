# cspell:ignore getline gsub
# Add a name-only pnpm patch entry, joining upstream's patchedDependencies block
# when one exists, and tag every resolved peer variant.
# Package versions come from upstream's lock; only context application decides
# whether the committed patch remains compatible. pnpm 11 rejects patch failures.
# Required variables: pkg, val (path/hash), q (key quote), tag (non-empty for
# a lock file), ph (patch hash).

BEGIN {
    depKey = q pkg q ":"
    snapPfx = q pkg "@"
    token = "(patch_hash=" ph ")"
    # Whether upstream already owns a top-level patchedDependencies decides,
    # before the first line prints, between joining that block and inserting
    # our own after `overrides:`. A second top-level key would either fail YAML
    # parsing or win over upstream's and drop one side's entries silently.
    while ((getline line < ARGV[1]) > 0) {
        if (line !~ /^patchedDependencies:/) continue
        if (line !~ /^patchedDependencies:[ \t]*$/)
            fail(ARGV[1] " has a patchedDependencies value that is not a block mapping: " line)
        nUpstream++
    }
    close(ARGV[1])
    if (nUpstream > 1)
        fail(ARGV[1] " declares patchedDependencies " nUpstream " times")
}

function fail(msg) {
    print "oxlint: " msg > "/dev/stderr"
    failed = 1
    exit 1
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

# Our entry goes after upstream's last entry, ahead of the blank lines that
# separate the block from the next top-level key.
function closeBlock() {
    print "  " q pkg q ": " val
    for (; nBlank > 0; nBlank--) print ""
    inBlock = 0
    nBlock++
}

{ t = trim($0) }

inBlock && /^[^ \t#]/ { closeBlock() }

# Inside upstream's block, accept only the shape pnpm writes: two-space
# `key: value` entries, comments and blank lines. Upstream naming our package
# itself, at any version, means its patch and ours would compete.
inBlock {
    if (t == "") { nBlank++; next }
    for (; nBlank > 0; nBlank--) print ""
    if (t !~ /^#/) {
        if ($0 !~ /^  [^ \t]/ || t !~ /: [^ \t]/)
            fail("cannot parse patchedDependencies entry: " $0)
        key = t
        gsub(/["']/, "", key)
        if (index(key, pkg ":") == 1 || index(key, pkg "@") == 1)
            fail("upstream's patchedDependencies already names " pkg ": " $0)
    }
    print
    next
}

/^patchedDependencies:/ {
    inBlock = 1
    section = $0
    print
    next
}

/^overrides:[ \t]*$/ {
    seenOverrides = 1
    print
    next
}

# Without an upstream block, pnpm writes one immediately before the first
# top-level key following `overrides:`. Anchoring there reproduces its own
# placement without caring which key that happens to be.
!nUpstream && seenOverrides && nBlock == 0 && /^[A-Za-z]/ {
    print "patchedDependencies:"
    print "  " q pkg q ": " val
    print ""
    nBlock = 1
    section = $0
    print
    next
}

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
    if (failed) exit 1
    # Upstream's block can be the file's last key.
    if (inBlock) closeBlock()
    if (!nUpstream && !seenOverrides) {
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
