# Compact portable-row module input for the workflow-rows check and the runtime-row fixture.
{pkgs}: {
  workflows.Rows = {
    text = "PORTABLE HEADER";
    steps.Check = {
      text = "Rows:\n\n{rows}";
      rows = {
        Added = {
          after = ["First"];
          before = ["Second"];
          text = "PORTABLE ADDED";
        };
        Disabled = {
          after = ["Second"];
          before = ["Source"];
          enable = false;
          text = "PORTABLE DISABLED";
        };
        First = {
          after = [];
          text = "PORTABLE FIRST\ncontinued";
        };
        Replaced = {
          after = ["Source"];
          text = "PORTABLE REPLACED";
        };
        Second = {
          after = ["Added"];
          text = "PORTABLE SECOND";
        };
        Source = {
          after = ["Second"];
          before = ["Replaced"];
          source = pkgs.writeText "row-source.md" "SOURCE\ncontinued";
        };
      };
    };
  };
}
