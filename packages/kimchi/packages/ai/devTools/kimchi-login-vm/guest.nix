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
  # The runner's stdio chardev has no QEMU mux, so Ctrl-a x never reaches
  # QEMU. Upstream runs QEMU with -no-reboot because it hangs after a guest
  # poweroff, so a guest reboot is the in-band way to stop the runner.
  security.sudo.extraRules = [
    {
      users = ["tester"];
      commands = [
        {
          command = "/run/current-system/sw/bin/reboot";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];
  services.getty.autologinUser = "tester";
  system.stateVersion = "26.05";
  users.users.tester.isNormalUser = true;
}
