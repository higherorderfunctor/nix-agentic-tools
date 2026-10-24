Add this to the rubric. The worker writes to it; every reviewer and adjudicator
checks it. Aim for the smallest change that meets the goal. For each addition,
ask what breaks if it is omitted: a named caller or a concrete input, path or
environment that the addition must refuse. With no such reason, remove the
addition. Before deleting a guard, name the input it refuses and show that the
input cannot reach it or is refused once elsewhere, checking every importer and
standalone evaluation. A real but unstated refused input is a naming finding:
state it where the guard lives. "No test" or "pre-existing" alone is not a
finding. Treat a wrapper, shim, compatibility branch or test kept only to
preserve an old shape as a finding. If the code can collapse into something
simpler while meeting the goal, say so. Ask the same question of process: each
extra check, role or round must name what breaks if it is skipped.
