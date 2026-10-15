# alias — remove before the ai-proxy work stream closes. The reconciler is the
# general library `lib/own`; this keeps `lib.ai.own` and its callers working
# until they import `mkBundle` from there.
{lib}: (import ../own {inherit lib;}).mkBundle
