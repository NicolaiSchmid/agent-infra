{
  description = "Agent workstation infrastructure";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Reuse Nicolai's existing agent VM/user environment. This input points at
    # the darwin flake subdir because that is where the current NixOS agent
    # modules live.
    dotfiles-src = {
      url = "path:/Users/nicolai/git/personal/dotfiles-nix";
      flake = false;
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }: let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
    pkgs = nixpkgs.legacyPackages.${system};
    formatterSystems = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forFormatterSystems = lib.genAttrs formatterSystems;

    mkNixos = name: modules:
      lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs;};
        modules =
          modules
          ++ [
            {
              system.configurationRevision = self.rev or self.dirtyRev or null;
              networking.hostName = name;
            }
          ];
      };
  in {
    nixosConfigurations = {
      # Bare-metal Hetzner host. It should do as little as possible: mirrored
      # disks, SSH/Tailscale, libvirt, backups, and running the atlas VM.
      black = mkNixos "black" [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        ./hosts/black/configuration.nix
      ];

      # Main agent workstation VM on black.
      atlas = mkNixos "atlas" [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        ./hosts/atlas/configuration.nix
      ];
    };

    checks.${system} = {
      black = self.nixosConfigurations.black.config.system.build.toplevel;
      atlas = self.nixosConfigurations.atlas.config.system.build.toplevel;
    };

    formatter = forFormatterSystems (fmtSystem: nixpkgs.legacyPackages.${fmtSystem}.alejandra);
  };
}
