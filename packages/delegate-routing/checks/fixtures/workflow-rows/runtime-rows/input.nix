# Runtime-row module input for the workflow-rows check; Claude replaces the portable Added row.
{pkgs}: let
  portable = import ../portable-rows/input.nix {inherit pkgs;};
in {
  ai.programs.delegate-routing = {
    inherit (portable) workflows;
    runtimes.claude.workflows.Rows.steps.Check.rows = {
      Added = {
        before = ["First"];
        text = "RUNTIME ADDED";
      };
    };
  };
}
