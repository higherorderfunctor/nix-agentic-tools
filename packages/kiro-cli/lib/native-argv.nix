# Native global options that consume a following argument (2.29.1 help).
# --cloud is boolean; --repo must hide a value such as "acp" from dispatch.
let
  chatValueFlags = ["--repo" "--resume-id"];
in {
  inherit chatValueFlags;
  launcherValueFlags = ["--agent"] ++ chatValueFlags;
}
