{pkgs, ...}: let
  atlasMemoryMiB = 52 * 1024;
  atlasVCpus = 12;
  atlasRootSize = "120G";
  atlasStateSize = "1000G";
  imageDir = "/var/lib/libvirt/images";
  atlasRoot = "${imageDir}/atlas-root.raw";
  atlasState = "${imageDir}/atlas-state.raw";
  atlasMac = "52:54:00:0c:55:8e";
  atlasIp = "192.168.122.226";
  defaultNetworkXml = pkgs.writeText "libvirt-default-network.xml" ''
    <network>
      <name>default</name>
      <forward mode='nat'/>
      <bridge name='virbr0' stp='on' delay='0'/>
      <ip address='192.168.122.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='192.168.122.2' end='192.168.122.254'/>
          <host mac='${atlasMac}' name='atlas' ip='${atlasIp}'/>
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
          <mac address='${atlasMac}'/>
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
      virsh net-update default add-last ip-dhcp-host \
        "<host mac='${atlasMac}' name='atlas' ip='${atlasIp}'/>" \
        --live --config >/dev/null 2>&1 || true
      if ! virsh dominfo atlas >/dev/null 2>&1; then
        virsh define ${atlasXml}
      fi
      virsh autostart atlas
    '';
  };

  systemd.services.atlas-tailscale-forward = {
    description = "Forward Atlas Tailscale UDP ports to the VM";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "libvirtd.service" "atlas-libvirt-domain.service"];
    wants = ["network-online.target"];
    requires = ["libvirtd.service"];
    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iptables
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      dnat_chain="ATLAS_VM_TS_DNAT"
      snat_chain="ATLAS_VM_TS_SNAT"
      fwd_chain="ATLAS_VM_TS_FWD"
      public_if="eth0"
      vm_if="virbr0"
      public_ip="65.109.71.108"
      ports="41641 41642"

      iptables -t nat -N "$dnat_chain" 2>/dev/null || true
      iptables -t nat -F "$dnat_chain"
      iptables -t nat -N "$snat_chain" 2>/dev/null || true
      iptables -t nat -F "$snat_chain"
      iptables -N "$fwd_chain" 2>/dev/null || true
      iptables -F "$fwd_chain"

      for port in $ports; do
        iptables -t nat -A "$dnat_chain" -i "$public_if" -p udp --dport "$port" -j DNAT --to-destination "${atlasIp}:$port"
        iptables -t nat -A "$snat_chain" -s "${atlasIp}/32" -o "$public_if" -p udp --sport "$port" -j SNAT --to-source "$public_ip:$port"
        iptables -A "$fwd_chain" -d "${atlasIp}/32" -i "$public_if" -o "$vm_if" -p udp --dport "$port" -j ACCEPT
        iptables -A "$fwd_chain" -s "${atlasIp}/32" -i "$vm_if" -o "$public_if" -p udp --sport "$port" -j ACCEPT
      done
      iptables -t nat -C PREROUTING -j "$dnat_chain" 2>/dev/null || iptables -t nat -A PREROUTING -j "$dnat_chain"
      iptables -t nat -C POSTROUTING -j "$snat_chain" 2>/dev/null || iptables -t nat -A POSTROUTING -j "$snat_chain"
      iptables -C FORWARD -j "$fwd_chain" 2>/dev/null || iptables -I FORWARD 1 -j "$fwd_chain"
    '';
    preStop = ''
      dnat_chain="ATLAS_VM_TS_DNAT"
      snat_chain="ATLAS_VM_TS_SNAT"
      fwd_chain="ATLAS_VM_TS_FWD"
      iptables -t nat -D PREROUTING -j "$dnat_chain" 2>/dev/null || true
      iptables -t nat -D POSTROUTING -j "$snat_chain" 2>/dev/null || true
      iptables -D FORWARD -j "$fwd_chain" 2>/dev/null || true
      iptables -t nat -F "$dnat_chain" 2>/dev/null || true
      iptables -t nat -X "$dnat_chain" 2>/dev/null || true
      iptables -t nat -F "$snat_chain" 2>/dev/null || true
      iptables -t nat -X "$snat_chain" 2>/dev/null || true
      iptables -F "$fwd_chain" 2>/dev/null || true
      iptables -X "$fwd_chain" 2>/dev/null || true
    '';
    reload = ''
      dnat_chain="ATLAS_VM_TS_DNAT"
      snat_chain="ATLAS_VM_TS_SNAT"
      fwd_chain="ATLAS_VM_TS_FWD"
      public_if="eth0"
      vm_if="virbr0"
      public_ip="65.109.71.108"
      ports="41641 41642"

      iptables -t nat -N "$dnat_chain" 2>/dev/null || true
      iptables -t nat -F "$dnat_chain"
      iptables -t nat -N "$snat_chain" 2>/dev/null || true
      iptables -t nat -F "$snat_chain"
      iptables -N "$fwd_chain" 2>/dev/null || true
      iptables -F "$fwd_chain"

      for port in $ports; do
        iptables -t nat -A "$dnat_chain" -i "$public_if" -p udp --dport "$port" -j DNAT --to-destination "${atlasIp}:$port"
        iptables -t nat -A "$snat_chain" -s "${atlasIp}/32" -o "$public_if" -p udp --sport "$port" -j SNAT --to-source "$public_ip:$port"
        iptables -A "$fwd_chain" -d "${atlasIp}/32" -i "$public_if" -o "$vm_if" -p udp --dport "$port" -j ACCEPT
        iptables -A "$fwd_chain" -s "${atlasIp}/32" -i "$vm_if" -o "$public_if" -p udp --sport "$port" -j ACCEPT
      done
      iptables -t nat -C PREROUTING -j "$dnat_chain" 2>/dev/null || iptables -t nat -A PREROUTING -j "$dnat_chain"
      iptables -t nat -C POSTROUTING -j "$snat_chain" 2>/dev/null || iptables -t nat -A POSTROUTING -j "$snat_chain"
      iptables -C FORWARD -j "$fwd_chain" 2>/dev/null || iptables -I FORWARD 1 -j "$fwd_chain"
    '';
  };
}
