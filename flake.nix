{
  description = "A lightweight, friendly NixOS installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkIso =
        system:
        nixpkgs.lib.nixosSystem {
          modules = [
            ./iso.nix
            { nixpkgs.hostPlatform = system; }
          ];
          specialArgs = { inherit nixos-hardware; };
        };
    in
    {
      nixosConfigurations = forAllSystems mkIso;

      # `nix build .#iso` builds the ISO for the architecture you're on.
      packages = forAllSystems (system: {
        iso = self.nixosConfigurations.${system}.config.system.build.isoImage;
        default = self.packages.${system}.iso;
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          unit = pkgs.runCommand "installer-unit-tests" { } ''
            ${pkgs.bash}/bin/bash ${./tests/test-install.sh} ${./install.sh} ${./first-boot.sh}
            touch $out
          '';
        }
      );
    };
}
