/**
 * @name process.env reads
 * @description How often each file reads each property of process.env,
 *              written as `process.env.NAME` or `process.env["NAME"]`.
 * @kind table
 * @id nix-agentic-tools/kimchi-env-reads
 */

import javascript

from File file, string name, int reads
where
  reads =
    strictcount(PropAccess read |
      read.getBase().(PropAccess).accesses(any(GlobalVarAccess process | process.getName() = "process"), "env") and
      read.getPropertyName() = name and
      read.getFile() = file
    )
select file.getRelativePath() as path, name, reads
