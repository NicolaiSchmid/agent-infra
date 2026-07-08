{pkgs, ...}: let
  atlasMemoryMiB = 52 * 1024;
  atlasVCpus = 12;
  atlasRootSize = "120G";
  atlasStateSize = "650G";
  imageDir = "/var/lib/libvirt/images";
  atlasRoot = "${imageDir}/atlas-root.raw";
  atlasState = "${imageDir}/atlas-state.raw";
  defaultNetworkXml = pkgs.writeText "libvirt-default-network.xml" ''
    <network>
      <name>default</name>
      <forward mode='nat'/>
      <bridge name='virbr0' stp='on' delay='0'/>
      <ip address='192.168.122.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='192.168.122.2' end='192.168.122.254'/>
        </dhcp>
      </ip>
    </network>
  '';
  atlasXml = pkgs.writeText "atlas.xml" ''
    <domain type='kvm'>
      <name>atlas</name>
      <memory unit='MiB'>${toString atlasMemoryMiB}</memory>
      <currentMemory unit='MiB'>${toString atlasMemoryMiB}</currentMemory>
      <vcpu placement='static'>${toString atlasVCpus}</vcpu>
      <os>
        <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
        <boot dev='hd'/>
      </os>
      <features>
        <acpi/>
        <apic/>
      </features>
      <cpu mode='host-passthrough' check='none'/>
      <devices>
        <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
          <source file='${atlasRoot}'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <disk type='file' device='disk'>
          <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
          <source file='${atlasState}'/>
          <target dev='vdb' bus='virtio'/>
        </disk>
        <interface type='network'>
          <source network='default'/>
          <model type='virtio'/>
        </interface>
        <console type='pty'>
          <target type='serial' port='0'/>
        </console>
        <serial type='pty'>
          <target port='0'/>
        </serial>
        <channel type='unix'>
          <target type='virtio' name='org.qemu.guest_agent.0'/>
        </channel>
        <rng model='virtio'>
          <backend model='random'>/dev/urandom</backend>
        </rng>
      </devices>
    </domain>
  '';
in {
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = false;
      swtpm.enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    libguestfs
    qemu
    virt-manager
  ];

  systemd.tmpfiles.rules = [
    "d ${imageDir} 0711 root root -"
    # New files in this directory should not use btrfs CoW. Existing files are
    # unaffected, so this must exist before atlas-root.raw/atlas-state.raw.
    "h ${imageDir} - - - - +C"
  ];

  systemd.services.atlas-libvirt-domain = {
    description = "Define atlas libvirt domain";
    wantedBy = ["multi-user.target"];
    after = ["libvirtd.service"];
    requires = ["libvirtd.service"];
    path = [
      pkgs.coreutils
      pkgs.libvirt
      pkgs.qemu
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      install -d -m 0711 ${imageDir}
      [ -e ${atlasRoot} ] || qemu-img create -f raw ${atlasRoot} ${atlasRootSize}
      [ -e ${atlasState} ] || qemu-img create -f raw ${atlasState} ${atlasStateSize}
      virsh net-info default >/dev/null 2>&1 || virsh net-define ${defaultNetworkXml}
      virsh net-start default >/dev/null 2>&1 || true
      virsh net-autostart default >/dev/null
      virsh define ${atlasXml}
      virsh autostart atlas
    '';
  };
}
