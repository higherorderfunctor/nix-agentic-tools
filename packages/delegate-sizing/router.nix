{
  delegate-sizing-router = {
    description = "Size model and effort before delegating";
    text =
      builtins.readFile ./fragments/skill-routing.md
      + "\nLoad the delegate-sizing skill before delegating when your harness provides it.\n";
  };
}
