To change any rule in delegate-routing for yourself, set
`ai.programs.delegate-routing.routing.<name>` in your own configuration, or
`ai.programs.delegate-routing.runtimes.<runtime>.routing.<name>` for one
runtime. An entry takes `enable`, `always`, `before`, `after`, and `text` or
`source`. A workflow step such as Review lives under
`workflows.<workflow>.steps.<step>` in the same two scopes and takes the same
fields except `always`. Follow Load delegate-routing for where to record rule
steering.
