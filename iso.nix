{
  lib,
  pkgs,
  modulesPath,
  nixos-hardware,
  ...
}:
let
  settings = import ./settings.nix;

  keymaps = pkgs.runCommand "console-keymaps" { } ''
    find -L ${pkgs.kbd}/share/keymaps -name '*.map.gz' -printf '%f\n' \
      | sed 's/\.map\.gz$//' | sort -u > $out
  '';

  installer = pkgs.writeShellApplication {
    name = "nixos-installer";
    runtimeInputs = with pkgs; [
      coreutils
      cryptsetup
      curl
      dosfstools
      e2fsprogs
      findutils
      gawk
      git
      gnugrep
      gum
      kbd
      lvm2
      networkmanager
      parted
      systemd
      util-linux
    ];
    text = builtins.readFile ./install.sh;
  };
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  # New machines need new drivers. ZFS often lags the latest kernel and the
  # installer doesn't use it.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # The serial console is how the VM tests drive the ISO. It's harmless on
  # machines without one, and the screen stays the main console.
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty1"
  ];

  networking.networkmanager.enable = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = [ installer ];

  environment.etc = {
    "nixos-installer/first-boot.sh".source = ./first-boot.sh;
    "nixos-installer/keymaps".source = keymaps;
    "nixos-installer/hardware-profiles".text = lib.concatLines (
      builtins.attrNames nixos-hardware.nixosModules
    );
    "nixos-installer/nixos-hardware-rev".text = nixos-hardware.rev;
    "nixos-installer/dotfiles-repo".text = settings.dotfilesRepo;
    "nixos-installer/dotfiles-branch".text = settings.dotfilesBranch;
  };

  # Leaves a normal shell if you quit, so you can look around or run it again.
  programs.bash.loginShellInit = ''
    if [ "$(tty)" = /dev/tty1 ]; then
      sudo nixos-installer
    fi
  '';
}
