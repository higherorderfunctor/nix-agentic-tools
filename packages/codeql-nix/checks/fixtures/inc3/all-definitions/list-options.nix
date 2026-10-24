{lib, ...}: {
  options.demo.answer = lib.mkOption {type = lib.types.listOf lib.types.str;};
}
