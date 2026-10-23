import nix.internal.RawBridge

from RawBridge::Anchor anchor
where
  anchor.getRelativePath() = "features.nix" and
  anchor.getKind() in ["=", "comment", "interpolation", "let", "path_expression"]
  or
  anchor.getRelativePath() = "recovered.nix" and anchor.getKind() = "integer_expression"
select anchor.getRelativePath(), anchor.getKind(), anchor.getStartByte(), anchor.getEndByte(),
  anchor.getMappingState(), anchor.getCandidateCount(),
  anchor.getRawLocation().getStartLine(), anchor.getRawLocation().getStartColumn(),
  anchor.getRawLocation().getEndLine(), anchor.getRawLocation().getEndColumn()
