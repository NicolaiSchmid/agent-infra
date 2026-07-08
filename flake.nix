{
  description = "Agent workstation infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Reuse Nicolai's existing agent VM/user environment. This input points at
    # the darwin flake subdir because that is where the current NixOS agent
    # modules live.
    dotfiles-src = {
      url = "github:NicolaiSchmid/dotfiles-nix";
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

    packages.${system} = {
      atlas-disko-images-script = self.nixosConfigurations.atlas.config.system.build.diskoImagesScript;

      install-atlas = pkgs.writeShellApplication {
        name = "install-atlas";
        runtimeInputs = with pkgs; [
          coreutils
          gnugrep
          libvirt
          nix
          qemu
          rsync
        ];
        text = ''
          set -euo pipefail

          image_dir=/var/lib/libvirt/images
          flake_ref=${self.outPath}
          build_memory=8192
          replace_root=0
          replace_state=0
          start_vm=0

          usage() {
            cat <<USAGE
          Usage: install-atlas [options]

          Options:
            --flake <ref>       Flake ref to build from. Defaults to this flake.
            --image-dir <path>  Libvirt image directory. Defaults to /var/lib/libvirt/images.
            --build-memory <m>  Memory in MiB for disko's image-build VM. Defaults to 8192.
            --replace-root      Replace atlas-root.raw if it already exists.
            --replace-state     Replace atlas-state.raw if it already exists. This destroys agent state.
            --start             Start atlas after installing images.
            -h, --help          Show this help.
          USAGE
          }

          while [ "$#" -gt 0 ]; do
            case "$1" in
              --flake)
                flake_ref="$2"
                shift 2
                ;;
              --image-dir)
                image_dir="$2"
                shift 2
                ;;
              --build-memory)
                build_memory="$2"
                shift 2
                ;;
              --replace-root)
                replace_root=1
                shift
                ;;
              --replace-state)
                replace_state=1
                shift
                ;;
              --start)
                start_vm=1
                shift
                ;;
              -h|--help)
                usage
                exit 0
                ;;
              *)
                usage >&2
                exit 2
                ;;
            esac
          done

          if [ "$(id -u)" -ne 0 ]; then
            echo "install-atlas must run as root on black." >&2
            exit 1
          fi

          if virsh domstate atlas 2>/dev/null | grep -q '^running$'; then
            echo "atlas is running; refusing to replace VM disks." >&2
            exit 1
          fi

          install -d -m 0711 "$image_dir"
          workdir=$(mktemp -d "$image_dir/atlas-image-build.XXXXXX")
          cleanup() {
            rm -rf "$workdir"
          }
          trap cleanup EXIT

          echo "Building atlas disko image script from $flake_ref"
          nix build "$flake_ref#nixosConfigurations.atlas.config.system.build.diskoImagesScript" --out-link "$workdir/disko-images-script"

          (
            cd "$workdir"
            ./disko-images-script --build-memory "$build_memory"
          )

          install_image() {
            src="$1"
            dst="$2"
            replace="$3"

            if [ -e "$dst" ] && [ "$replace" -ne 1 ]; then
              echo "$dst exists; leaving it untouched."
              return
            fi

            tmp="$dst.tmp.$$"
            rm -f "$tmp"
            rsync --sparse --inplace "$src" "$tmp"
            chmod 0644 "$tmp"
            mv "$tmp" "$dst"
          }

          install_image "$workdir/atlas-root.raw" "$image_dir/atlas-root.raw" "$replace_root"
          install_image "$workdir/atlas-state.raw" "$image_dir/atlas-state.raw" "$replace_state"

          systemctl start atlas-libvirt-domain.service

          if [ "$start_vm" -eq 1 ]; then
            virsh start atlas || true
          fi

          echo "atlas images are installed in $image_dir"
        '';
      };
    };

    apps.${system}.install-atlas = {
      type = "app";
      program = "${self.packages.${system}.install-atlas}/bin/install-atlas";
    };

    formatter = forFormatterSystems (fmtSystem: nixpkgs.legacyPackages.${fmtSystem}.alejandra);
  };
}
