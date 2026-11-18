# Match eve-deployments' gVisor CI fixture, including host Unix-socket support.
{pkgs}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "hosted-runner-runsc";
  version = "20261102.0";
  src = pkgs.fetchurl {
    url = "https://github.com/google/gvisor/releases/download/release-20261102.0/gvisor-x86_64.tar.bz2";
    sha256 = "6f6b1a8f0f4665a403238135167d0d990bfaeaff5544abf68f5e0d822b35484a";
  };
  nativeBuildInputs = [pkgs.bzip2];
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 runsc "$out/bin/runsc"
    install -Dm755 containerd-shim-runsc-v1 "$out/bin/containerd-shim-runsc-v1"
    cp -r gvisor-bin "$out/bin/gvisor-bin"
    runHook postInstall
  '';
}
