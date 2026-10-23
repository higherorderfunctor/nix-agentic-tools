import nix.internal.RawBridge

from RawBridge::Anchor anchor, string locationState
where
  (anchor.getRelativePath() = "bridge.nix" or
   anchor.getRelativePath() = "multiline.nix" and anchor.getKind() = "source_code") and
  (
    exists(anchor.getRawLocation()) and locationState = "location"
    or
    not exists(anchor.getRawLocation()) and locationState = "none"
  )
select anchor.getRelativePath(), anchor.getStartByte(), anchor.getEndByte(), anchor.getKind(),
  anchor.getChildPath(), anchor.getMappingState(), anchor.getCandidateCount(), locationState
