import nix.internal.RawBridge

from RawBridge::Anchor anchor
where
  anchor.getRelativePath() = "empty.nix" and anchor.getKind() = "source_code" and
  anchor.getStartByte() = 0 and anchor.getEndByte() = 0 and
  (
    anchor.getMappingState() = "unmapped" and anchor.getCandidateCount() = 0 and
    not exists(anchor.getRawLocation())
    or
    anchor.getMappingState() = "unique" and anchor.getCandidateCount() = 1 and
    anchor.getRawLocation().getStartLine() = 1 and
    anchor.getRawLocation().getStartColumn() = 1 and
    anchor.getRawLocation().getEndLine() = 1 and
    anchor.getRawLocation().getEndColumn() = 0
  )
select anchor.getRelativePath(), "empty span preserved without a fabricated location"
