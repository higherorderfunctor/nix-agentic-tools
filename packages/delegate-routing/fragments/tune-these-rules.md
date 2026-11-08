To change any rule in delegate-routing for yourself, set
`ai.programs.delegate-routing.routing.<name>` in your own configuration, or
`ai.programs.delegate-routing.runtimes.<runtime>.routing.<name>` for one
runtime. An entry takes `enable`, `always`, `before`, `after`, and `text` or
`source`. A workflow step such as Review lives under
`workflows.<workflow>.steps.<step>` in the same two scopes and takes the same
fields except `always`.

Delegate-routing owns these delegation and review rules; the small router is
their always-on entrypoint. When someone steers how they should work, propose a
change to their source — the delegate-routing package's fragments, or for a
consumer its `ai.programs.delegate-routing` routing and workflows entries — so
it is committed and distributed. Do not edit a rendered rule or skill file, and
do not record that steering in memory or as a house rule that changes how the
skill is read.
