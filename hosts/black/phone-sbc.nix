# Persist the synthetic-call spike; carrier ingress awaits an account and certificate.
{
  pkgs,
  lib,
  ...
}: let
  livekitHost = "1t72z3s8t1h.sip.livekit.cloud";
  # Frankfurt SIP frontends verified 2026-10-31. Keep the hostname for TLS/SNI.
  livekitAddresses = ["161.115.161.126" "161.115.161.149"];
  publicAddress = "65.109.71.108";
in {
  networking.hosts = builtins.listToAttrs (map (address: {
      name = address;
      value = [livekitHost];
    })
    livekitAddresses);

  # Only encrypted media from the pinned LiveKit frontends. No public SIP
  # ingress until the carrier's identity, TLS certificate and routing exist.
  networking.firewall.extraCommands = builtins.concatStringsSep "\n" (map (address: "iptables -A nixos-fw -s ${address}/32 -p udp --dport 20000:20200 -j nixos-fw-accept") livekitAddresses);
  networking.firewall.extraStopCommands = builtins.concatStringsSep "\n" (map (address: "iptables -D nixos-fw -s ${address}/32 -p udp --dport 20000:20200 -j nixos-fw-accept || true") livekitAddresses);

  services.asterisk = {
    enable = true;
    # No sample listeners, CDR/CEL backends, manager API or recording modules.
    useTheseDefaultConfFiles = ["acl.conf" "features.conf" "indications.conf" "pjproject.conf" "stasis.conf" "ccss.conf" "udptl.conf"];
    confFiles = {
      "modules.conf" = ''
        [modules]
        autoload=no
        load=res_pjproject.so
        load=res_sorcery_config.so
        load=res_sorcery_memory.so
        load=res_sorcery_astdb.so
        load=res_sorcery_realtime.so
        load=res_pjsip.so
        load=res_pjsip_endpoint_identifier_ip.so
        load=res_pjsip_pubsub.so
        load=res_pjsip_session.so
        load=res_pjsip_sdp_rtp.so
        load=res_pjsip_nat.so
        load=res_pjsip_caller_id.so
        load=res_pjsip_sips_contact.so
        load=res_pjsip_dtmf_info.so
        load=res_rtp_asterisk.so
        require=res_srtp.so
        require=chan_pjsip.so
        load=codec_alaw.so
        load=codec_ulaw.so
        load=pbx_config.so
        load=app_dial.so
        load=app_playback.so
        load=app_stack.so
        load=app_verbose.so
        load=func_channel.so
        load=format_wav.so
      '';
      "cdr.conf" = ''
        [general]
        enable=no
      '';
      "cel.conf" = ''
        [general]
        enable=no
      '';
      "logger.conf" = ''
        [general]
        [logfiles]
        console => warning,error
      '';
      "pjsip.conf" = ''
        [global]
        type=global
        user_agent=modus-sbc
        endpoint_identifier_order=ip

        [livekit-tls]
        type=transport
        protocol=tls
        bind=0.0.0.0:5061
        method=tlsv1_2
        ca_list_file=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        verify_server=yes
        allow_wildcard_certs=yes
        external_media_address=${publicAddress}
        external_signaling_address=${publicAddress}

        [livekit]
        type=aor
        contact=sip:${livekitHost}:5061;transport=tls

        [livekit]
        type=endpoint
        transport=livekit-tls
        aors=livekit
        context=reject-inbound
        allow_transfer=no
        disallow=all
        allow=alaw,ulaw
        media_encryption=sdes
        media_encryption_optimistic=no
        direct_media=no
        rtp_symmetric=yes
        force_rport=yes
        rewrite_contact=yes

        [livekit]
        type=identify
        endpoint=livekit
        match=${builtins.concatStringsSep "," livekitAddresses}
      '';
      "extensions.conf" = ''
        [general]
        static=yes
        writeprotect=yes
        [reject-inbound]
        exten => _X!,1,Hangup(21)
        exten => s,1,Hangup(21)
      '';
      "rtp.conf" = ''
        [general]
        rtpstart=20000
        rtpend=20200
        strictrtp=yes
      '';
    };
  };
  systemd.services.asterisk = {
    after = ["network-online.target"];
    wants = ["network-online.target"];
    # The upstream unit starts as root, then Asterisk drops privileges.
    preStart = lib.mkAfter "chown asterisk:asterisk /run/asterisk";
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
      RuntimeDirectory = "asterisk";
      RuntimeDirectoryMode = "0750";
    };
  };
}
