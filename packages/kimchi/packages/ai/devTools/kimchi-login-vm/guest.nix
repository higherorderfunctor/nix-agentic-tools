_: {
  microvm = {
    graphics.enable = false;
    hypervisor = "qemu";
    interfaces = [
      {
        id = "usernet";
        mac = "02:00:00:00:00:01";
        type = "user";
      }
    ];
    mem = 1024;
    qemu.serialConsole = true;
    shares = [
      {
        mountPoint = "/nix/store";
        proto = "9p";
        readOnly = true;
        source = "/nix/store";
        tag = "ro-store";
      }
    ];
    socket = null;
    vcpu = 1;
    volumes = [];
    writableStoreOverlay = null;
  };

  # All writable state, including the user's home, disappears on shutdown.
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = ["mode=0755" "size=50%"];
  };
  networking = {
    hostName = "kimchi-login-vm";
    useDHCP = true;
  };
  services.getty.autologinUser = "tester";
  system.stateVersion = "26.05";
  users.users.tester = {
    isNormalUser = true;
    password = "";
  };
}
