<!-- TODO: remove this file before merging to main -->

parallel nix update and github api key
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
