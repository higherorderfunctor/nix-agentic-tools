# Compact portable-row module input for the workflow-rows check and the runtime-row fixture.
{pkgs}: {
  workflows.Rows = {
    text = "PORTABLE HEADER";
    steps.Check = {
      text = "Rows:\n\n{rows}";
      rows = {
        Added = {
          after = ["First"];
          text = "PORTABLE ADDED";
        };
        Disabled = {
          enable = false;
          text = "PORTABLE DISABLED";
        };
        First.text = "PORTABLE FIRST\ncontinued";
        Replaced.text = "PORTABLE REPLACED";
        Source = {
          after = ["Added"];
          # The sole edge to Replaced; ignoring before now moves Replaced ahead of Source.
          before = ["Replaced"];
          source = pkgs.writeText "row-source.md" "SOURCE";
        };
      };
    };
  };
}
