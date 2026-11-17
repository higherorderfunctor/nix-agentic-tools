# Review policy options used by both module backends and direct skill builders.
# Nix defaults become manifest fields; the helper applies them to routes and plans.
{lib}: let
  vocabulary = import ./vocabulary.nix;
  roles = ["finder" "first-check" "investigator" "judge" "mechanical" "planner" "second-check" "writer"];
  workers = ["investigator" "mechanical" "writer"];
  roleList = lib.types.listOf (lib.types.enum roles);
in {
  options = {
    planCheck = {
      requireRubric = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Require a non-empty saved rubric and its full bytes in every launch brief.";
      };
      requireSize = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Require per-kind added/removed counts on every plan unit.";
      };
      requiredReviewRoles = lib.mkOption {
        type = roleList;
        default = ["first-check"];
        description = "Review roles required on every plan unit; empty permits units without review.";
      };
      workerRoles = lib.mkOption {
        type = roleList;
        default = workers;
        description = "Roles eligible to be the single worker in each plan unit.";
      };
    };
    roles = lib.genAttrs roles (role: {
      tiers = lib.mkOption {
        type = lib.types.listOf (lib.types.enum vocabulary.tiers);
        default =
          if builtins.elem role workers
          then vocabulary.tiers
          else ["frontier" "strong"];
        description = "Allowed capability tiers for the ${role} role; empty disables candidates for this role.";
      };
    });
  };
}
