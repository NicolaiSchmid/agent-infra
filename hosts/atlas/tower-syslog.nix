{pkgs, ...}: let
  logDir = "/srv/agents-state/logs/tower";
  receiverConfig = pkgs.writeText "tower-syslog.conf" ''
    module(load="imtcp")
    ruleset(name="tower") {
      if ($fromhost-ip == "100.64.0.99") then {
        action(type="omfile" file="${logDir}/syslog.log"
          template="RSYSLOG_FileFormat" fileCreateMode="0640"
          dirCreateMode="0750" sync="on")
      }
      stop
    }
    input(type="imtcp" address="100.122.138.66" port="5514" ruleset="tower")
  '';
in {
  # No public listener or firewall opening. Tailscale encrypts the transport;
  # the dedicated ruleset accepts only Tower's host plugin address, not tower-arr.
  systemd.tmpfiles.rules = ["d ${logDir} 0750 root root -"];
  systemd.services.tower-syslog = {
    description = "Persistent Tower syslog receiver over Tailscale";
    wantedBy = ["multi-user.target"];
    wants = ["tailscaled.service" "network-online.target"];
    after = ["tailscaled.service" "network-online.target"];
    unitConfig = {
      StartLimitIntervalSec = 0;
      RequiresMountsFor = logDir;
    };
    serviceConfig = {
      ExecStartPre = "${pkgs.rsyslog}/bin/rsyslogd -N1 -f ${receiverConfig}";
      ExecStart = "${pkgs.rsyslog}/bin/rsyslogd -n -i /run/tower-syslog/rsyslog.pid -f ${receiverConfig}";
      Restart = "always";
      RestartSec = "10s";
      RuntimeDirectory = "tower-syslog";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ReadWritePaths = [logDir];
    };
  };
  systemd.services.tower-syslog-rotate = {
    description = "Rotate persistent Tower syslog";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "tower-syslog-rotate";
      ExecStart = "${pkgs.logrotate}/bin/logrotate --state /var/lib/tower-syslog-rotate/status ${pkgs.writeText "tower-logrotate.conf" ''
        ${logDir}/syslog.log {
          daily
          maxsize 16M
          rotate 90
          maxage 90
          compress
          delaycompress
          missingok
          notifempty
          create 0640 root root
          postrotate
            ${pkgs.systemd}/bin/systemctl kill -s HUP tower-syslog.service || true
          endscript
        }
      ''}";
    };
    unitConfig.RequiresMountsFor = logDir;
  };
  systemd.timers.tower-syslog-rotate = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };
}
