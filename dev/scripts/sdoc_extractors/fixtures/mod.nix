# The tree-sitter extractor's fixture module. This header comment ALSO sits
# directly above the first item, which is the doubled-marker trap: parse it
# once as the file's and once as the module's and one requirement renders as
# two identical range pointers.
# @relation(REQ-FILE, scope=file)
{
  config,
  lib,
  ...
}: let
  cfg = config.services.foo;
in {
  options.services.foo = {
    # @relation(REQ-ENABLE, scope=function)
    enable = lib.mkEnableOption "foo";

    port = lib.mkOption {
      type = lib.types.port;
      default = 1234;
    };
  };

  # A comment with a blank line under it documents nothing below.

  config = lib.mkIf cfg.enable {
    systemd.services.foo.script = "run";
  };
}
