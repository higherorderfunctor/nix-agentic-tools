/**
 * @name Environment reads
 * @description One row per named read of process.env and the runtime that
 *              reads it, and a "fail" row for each reason the reads cannot be
 *              listed. The environment transform turns these into
 *              extracted.json environment.variables.
 * @kind table
 * @id nix-agentic-tools/kimchi-environment-reads
 */

import EnvReads

from string kind, string name, string runtime, string where_
where
  kind = "read" and
  exists(DataFlow::Node site |
    listedRead(site, name) and
    runtime = runtimeOf(site.getFile()) and
    where_ = site.getFile().getRelativePath() + ":" + site.getStartLine()
  )
  or
  kind = "fail" and runtime = "" and readFailure(name, where_)
select kind, name, runtime, where_
