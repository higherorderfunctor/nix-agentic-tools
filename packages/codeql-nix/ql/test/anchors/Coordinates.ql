import nix.internal.RawBridge

from RawBridge::Anchor anchor
where
  (
    anchor.getRelativePath() = "coordinates.nix" and anchor.getKind() = "integer_expression"
    or
    anchor.getRelativePath() = "newline.nix" and anchor.getKind() = "source_code"
  )
select anchor.getRelativePath(), anchor.getStartByte(), anchor.getEndByte(),
  anchor.getRawLocation().getStartLine(), anchor.getRawLocation().getStartColumn(),
  anchor.getRawLocation().getEndLine(), anchor.getRawLocation().getEndColumn()
