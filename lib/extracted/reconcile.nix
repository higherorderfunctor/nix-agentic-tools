# The new-key rule over committed facts and rows. It needs only nixpkgs lib,
# so a consumer that declares options before `pkgs` exists (the git tools'
# option modules) can call it.
{lib}: let
  inherit (import ../runtime-values {inherit lib;}) classify;
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
in {
  # Facts carry upstream types. Only string leaves and string-to-string maps
  # enter the classifier; objects and booleans are outside its contract.
  reconcile = surfaces:
    lib.mapAttrs (surface: {
      facts,
      fields ? [],
      needs ? [],
      rows,
      secretNeeds,
      uses ? {},
    }: let
      names = lib.sort builtins.lessThan (lib.unique (builtins.attrNames facts ++ builtins.attrNames rows ++ builtins.attrNames uses));
      perName = name: let
        present = facts ? ${name};
        recorded = rows ? ${name};
        fact = facts.${name} or {};
        raw = rows.${name} or {};
        row =
          if builtins.isAttrs raw
          then raw
          else {};
        replace = row.replace or [];
        replaceValid = builtins.isList replace && lib.all (field: builtins.isString field && row ? ${field} && builtins.elem field (fields ++ needs)) replace;
        allowed = fields ++ needs ++ ["ignored" "replace"];
        hand = builtins.removeAttrs row ["ignored" "replace"];
        badFields = lib.filter (field:
          !(builtins.elem field allowed)
          || !nonBlank hand.${field}
          || (fact.${field} or null != null && !(replaceValid && builtins.elem field replace)))
        (builtins.attrNames hand);
        ignored = row ? ignored && nonBlank row.ignored;
        entry = fact // lib.filterAttrs (field: _: !(builtins.elem field badFields)) hand;
        missing = lib.filter (field: entry.${field} or null == null) needs;
        # An explicit type replacement must not hide a known string secret.
        # Use a filled type only when extraction could not derive one.
        typed =
          if fact.type or null == null
          then entry
          else fact;
        stringValued = typed.type or null == "string" || (typed.type or null == "object" && typed.additionalProperties.type or null == "string");
        secret =
          stringValued
          && classify {
            path = [name];
            hints = fact;
          };
        missingSecret = lib.filter (field: entry.${field} or null == null) secretNeeds;
        badReasons =
          badFields
          ++ lib.optional (!builtins.isAttrs raw) "row must be an object"
          ++ lib.optional (!replaceValid) "replace must list supplied allowed fields"
          ++ lib.optional (row ? ignored && !ignored) "ignored must give a non-blank reason";
        bad = badReasons != [];
        failure = kind: details: {
          inherit kind name surface;
          inherit details;
        };
        added = present && !ignored && !bad && missing == [] && !secret && !recorded;
      in {
        inherit added entry ignored;
        failures =
          lib.optional (!present) (failure "removed" (uses.${name} or "delete the stale row"))
          ++ lib.optional bad (failure "bad-row" badReasons)
          ++ lib.optionals (present && !ignored) (
            lib.optional (missing != []) (failure "needs-human" missing)
            ++ lib.optional (secret && (!recorded || missingSecret != [])) (failure "secret" missingSecret)
          )
          ++ lib.optional added (failure "unrecorded" "regenerate the rows");
      };
      results = lib.genAttrs names perName;
    in {
      added = lib.filter (name: results.${name}.added) names;
      entries = lib.mapAttrs (_: result: result.entry) (lib.filterAttrs (name: result: facts ? ${name} && !result.ignored) results);
      failures = lib.concatMap (name: results.${name}.failures) names;
    })
    surfaces;

  # Preserve hand rows and grouped ignores, adding only accepted new names.
  withAdded = rows: results:
    rows // lib.mapAttrs (surface: result: (rows.${surface} or {}) // lib.genAttrs result.added (_: {})) results;
}
