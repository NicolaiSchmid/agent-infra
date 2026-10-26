# Pinned agent CLIs shared by atlas and black. nixos-26.05 lags upstream by
# weeks, so claude-code/codex/opencode are overridden with release binaries.
{...}: {
  nixpkgs.overlays = [
    (final: prev: {
      claude-code = prev.claude-code.overrideAttrs (_old: {
        version = "2.1.302";
        src = final.fetchurl {
          url = "https://downloads.claude.ai/claude-code-releases/2.1.302/linux-x64/claude";
          hash = "sha256-YNfrfxL7sopSUz/ovliECXQDViqgLcc5kaAhxwZ+KaU=";
        };
      });

      codex = final.stdenvNoCC.mkDerivation rec {
        pname = "codex";
        version = "0.163.0";

        src = final.fetchurl {
          url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
          hash = "sha256-vrM56OzZugV6a7Lcga2MpHSBLt+/D8UFbKgYeXZI3eQ=";
        };

        codeModeHostSrc = final.fetchurl {
          url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz";
          hash = "sha256-MUJjEoumWS5+gHwmXe6vkoppK3Lcv+teCyDJQjtwNSk=";
        };

        nativeBuildInputs = [final.makeWrapper];

        unpackPhase = ''
          tar -xzf "$src"
          tar -xzf "$codeModeHostSrc"
        '';

        installPhase = ''
          runHook preInstall

          install -Dm755 codex-x86_64-unknown-linux-musl "$out/bin/codex"
          install -Dm755 codex-code-mode-host-x86_64-unknown-linux-musl "$out/bin/codex-code-mode-host"
          wrapProgram "$out/bin/codex" \
            --prefix PATH : ${final.lib.makeBinPath [
            final.bubblewrap
            final.ripgrep
          ]}

          runHook postInstall
        '';

        meta =
          prev.codex.meta
          // {
            sourceProvenance = [final.lib.sourceTypes.binaryNativeCode];
            platforms = ["x86_64-linux"];
          };
      };

      opencode = final.stdenvNoCC.mkDerivation rec {
        pname = "opencode";
        version = "1.18.32";

        src = final.fetchurl {
          url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
          hash = "sha256-MEbgQE/cYPuAMH56R4JLoHR3NkF4pNCbqoVISW3W1Ds=";
        };

        unpackPhase = ''
          tar -xzf "$src"
        '';

        installPhase = ''
          install -Dm755 opencode "$out/bin/opencode"
        '';

        meta = {
          description = "AI coding agent built for the terminal";
          homepage = "https://opencode.ai";
          sourceProvenance = [final.lib.sourceTypes.binaryNativeCode];
          platforms = ["x86_64-linux"];
        };
      };
    })
  ];
}
