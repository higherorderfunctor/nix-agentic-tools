# Listing check names must not read check values. `unavailable` throws when
# read, so a strict `checks` option, or any name-time forcing, fails the
# `check-laziness` assertion in checks/facets/facet-mock.nix. Marking it
# unpublished holds `unpublishedChecks` to the same rule.
{pkgs, ...}: {
  checks = {
    available = pkgs.runCommandLocal "available-check-control" {} "touch $out";
    unavailable = throw "unrelated check must stay lazy";
  };
  unpublishedChecks = ["unavailable"];
}
