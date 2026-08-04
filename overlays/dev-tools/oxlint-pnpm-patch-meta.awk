# Add pnpm `patchedDependencies` metadata to a workspace or lock file BY KEY
# rather than by line number.
#
# Why this is not a patch hunk: the edit carries no judgement. It inserts one
# block and stamps one identical `(patch_hash=…)` token wherever pnpm names
# the resolved dependency. Upstream reshuffles those peer variants freely —
# oxc collapsed five `@napi-rs/cli@3.8.2(…)` snapshot keys to two between
# 9c8c5e5 and 1501ccf — and a positional diff dies on every such reshuffle,
# holding the target back until someone realigns hunks by hand. Keying off the
# names instead makes reshuffles invisible.
#
# What still fails loud, deliberately: the dependency moving off the pinned
# version. That changes both the patch target and the patch hash, so it is a
# real human decision rather than drift, and the END assertions stop the build
# instead of silently producing an unpatched tree.
#
# Variables (all required; `ph` only read when `tag` is set):
#   pkg  dependency name, e.g. @napi-rs/cli
#   ver  pinned dependency version, e.g. 3.8.2
#   val  block value — the patch hash (lock) or the patch path (workspace)
#   q    quote character upstream uses for keys in THIS file (lock: ' ws: ")
#   tag  non-empty to also stamp (patch_hash=…) onto resolved references
#   ph   the patch hash

BEGIN {
    depKey = q pkg q ":"
    catKey = q pkg q ": " ver
    snapPfx = q pkg "@" ver "("
    verPfx = "version: " ver "("
    token = "(patch_hash=" ph ")("
}

function trim(s) {
    sub(/^[ \t]+/, "", s)
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
    print "  " q pkg "@" ver q ": " val
    print ""
    nBlock = 1
    print
    next
}

{ t = trim($0) }

# Workspace only: the catalog pin is what decides whether our patch file still
# describes the dependency upstream actually resolves.
tag == "" && index(t, catKey) == 1 {
    nCatalog++
    print
    next
}

# An importer's `version:` line names the resolved peer set but NOT the
# package, so it is identifiable only from the dependency key above it.
tag != "" && t == depKey {
    inDep = 1
    print
    next
}

tag != "" && inDep && index(t, verPfx) == 1 {
    sub(/\(/, token, $0)
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

# Snapshot keys name the package inline. The bare `@<ver>:` entry under
# `packages:` carries no peer suffix and pnpm does not patch-tag it.
tag != "" && index(t, snapPfx) == 1 {
    sub(/\(/, token, $0)
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
    if (tag == "" && nCatalog == 0) {
        print "oxlint: catalog no longer pins " pkg " at " ver " — the patch file and its hash both need regenerating" > "/dev/stderr"
        exit 1
    }
    if (tag != "" && nImp == 0) {
        print "oxlint: no importer resolves " pkg "@" ver " — the pinned version moved" > "/dev/stderr"
        exit 1
    }
    if (tag != "" && nSnap == 0) {
        print "oxlint: no snapshot entry for " pkg "@" ver " — the pinned version moved" > "/dev/stderr"
        exit 1
    }
    if (tag != "") {
        print "oxlint: patch_hash stamped on " nImp " importer + " nSnap " snapshot entries" > "/dev/stderr"
    }
}
