<!-- TODO: remove this file before merging to main -->

SWITCH MCPS OR NODE BASED PACKAGES TO BUN

SINGLE SOURCER OF YRUTH FOR FLAKE INPUTS KINDA NUTS NEED EXPLAIN

● Resume prompt:

▎ Continue the nix-update migration on refactor/ai-factory-architecture. Check
.remember/remember.md for the remaining work list. Start with item 1 (replace custom TOML parser
with builtins.fromTOML) and work through the list. Don't push until everything builds end-to-end.
update script caches (<REPO>/.cache?</REPO>

why update script takes so much cpu, did direnv fire maybe?

ME: doub;e check work
ME: test in nixos-config

- Update overlays/README.md table to reflect all the source changes made tonight
- Document the unfree guard pattern as an architecture fragment

---

Some other moves if possible (will have to update scripts most likely to find these files or other config files).

```
config/ # new directory
  cspell/
    cspell.json
  project-terms.txt - break this file up into sections, it supports comments
                      easier to audit later to remove stale terms
  nvfetcher/
    nvfetcher.toml
  agnix/
    agnix.toml
overlays/
  sources/ # move all generated files (was .nvfetcher)
    generated.{nix.json}
    hashes.json # for the ones you have to compute yourself like dep hashes
    locks/\*.json # may be removed but we aren't redoing locks anymore so may be gone
```

---

Are we (and this may be tricky) able to warn if someone overrides
this flakes input nixpkgs or any other inputs, and, if possible check if cachix is set, then
produce a warning they are bypassing cachix and remove the follows?
or if they are not using cachix, then produce a warning that they should be using cachix and remove the follows?

so.. if we cannot see the users cachix/substitutors
a) warn if inputs are overridden about producing a cache miss.

if we cant see the users cachix/substitutors, then
b) warn if cachix is not substitors that we have prebuilt binaries from cachix
c) only warn (a) if (b) passes (they have our substitors) but they are overriding inputs, otherwise just warn about (b) and not (a) since they are already bypassing cachix

These are only warnings, we wont break their build.
if possible provide an option to disable the warning? not sure how easy this is with different module systems possibly in play (or even no module if consumer just uses overlays and no hm/devenv). just thinking about it from a UX perspective what we may be able to do.
