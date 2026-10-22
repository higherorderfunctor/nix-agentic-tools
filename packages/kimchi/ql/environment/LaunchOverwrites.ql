/**
 * @name Launch overwrites
 * @description One "fixed" row per variable kimchi/src/entry.ts assigns on
 *              every launch before anything reads it, and a "fail" row for
 *              each reason the order cannot be known.
 * @kind table
 * @id nix-agentic-tools/kimchi-launch-overwrites
 */

import Overwrites

from string kind, string name, string where_
where
  kind = "fixed" and overwritten(name) and where_ = entry().getFile().getRelativePath()
  or
  kind = "fail" and overwriteFailure(name, where_)
select kind, name, where_
