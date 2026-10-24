{lib, ...}: {
  options.demo.answer = lib.mkOption {type = lib.types.nullOr lib.types.int;};
}
