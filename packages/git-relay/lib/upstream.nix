# Evaluation and the launcher accept the same SSH endpoints and pin-file names.
{lib}: let
  hostPattern = "[A-Za-z0-9][A-Za-z0-9.-]*";
  # A leading colon in the path is Git's helper:: syntax, not SSH.
  scpPattern = "([A-Za-z0-9._-]+@)?(${hostPattern}):([^:[:cntrl:]][^[:cntrl:]]*)";
  sshPattern = "ssh://([A-Za-z0-9._-]+@)?(${hostPattern})(:[0-9]+)?/([^[:cntrl:]]+)";
in {
  inherit hostPattern scpPattern sshPattern;
  host = upstream: let
    ssh = builtins.match sshPattern upstream;
    scp = builtins.match scpPattern upstream;
  in
    if ssh != null
    then builtins.elemAt ssh 1
    # A scheme such as https:// must not be mistaken for scp host:path.
    else if !lib.hasInfix "://" upstream && scp != null
    then builtins.elemAt scp 1
    else null;
}
