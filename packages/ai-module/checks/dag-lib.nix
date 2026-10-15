# Home Manager's DAG constructors reduced to their edges, so a check reads the
# lowered activation graph without importing Home Manager.
lib:
lib
// {
  hm.dag = {
    entryAfter = after: text: {inherit after text;};
    entryBetween = before: after: text: {inherit after before text;};
  };
}
