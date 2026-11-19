# TCP ports that services on black listen on and the tailnet must not reach.
# tailscale0 is trusted on black, and tailscaled's own chain `ts-input` runs
# ahead of `nixos-fw` in the filter table's INPUT and accepts everything on
# tailscale0, so a refuse rule inside `nixos-fw` never matches. Read-only on
# black on 2026-11-19: INPUT jumped to ts-input first, the nixos-fw tailscale0
# refuse rule had counted 0 packets, and from Atlas over the tailnet E2B's
# client-proxy health port 3003 answered 200 and the orchestrator's 5007
# answered 400.
#
# The mangle table's INPUT hook runs before the filter table's, and tailscaled
# does not touch it, so the refusal lives there. Mangle allows no REJECT, so
# new connections are dropped: a tailnet client times out instead of being
# refused.
{
  config,
  lib,
  ...
}: let
  ports = config.networking.firewall.tailnetRefusedTCPPorts;
  # The firewall module defines ip46tables for these scripts. Idempotent, so
  # the start script can run again on reload.
  remove = ''
    ip46tables -t mangle -D INPUT -i tailscale0 -j tailnet-refuse 2>/dev/null || true
    ip46tables -t mangle -F tailnet-refuse 2>/dev/null || true
    ip46tables -t mangle -X tailnet-refuse 2>/dev/null || true
  '';
in {
  options.networking.firewall.tailnetRefusedTCPPorts = lib.mkOption {
    # Strings, so a module can name an iptables range ("5007:5009").
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "TCP ports or ranges whose new connections from tailscale0 are dropped before tailscaled's ts-input accepts them.";
  };

  config.networking.firewall = lib.mkIf (ports != []) {
    extraCommands = ''
      ${remove}
      ip46tables -t mangle -N tailnet-refuse
      ip46tables -t mangle -A tailnet-refuse -p tcp -m multiport --dports ${lib.concatStringsSep "," ports} -m conntrack --ctstate NEW -j DROP
      ip46tables -t mangle -I INPUT -i tailscale0 -j tailnet-refuse
    '';
    extraStopCommands = remove;
  };
}
