# The self-hosted Convex deployments on black, read by convex.nix (one
# backend per entry) and routes.nix (which projects may route to which
# deployment). Adding a deployment: runbooks/black-client-data-demo.md.
#
# Every setting a deployment does not share with the template
# (convex/compose.yaml) lives in its entry here, and `nixos-rebuild switch`
# is the only way it reaches black (convex.nix removes hand-made systemd
# overrides on activation). Per entry:
# - cloudPort, sitePort, memory, cpus: required;
# - image: replaces the template's backend image;
# - environment: added to or replacing the template's backend environment;
# - slice: runs the backend in its own <slice>.slice with the entry's memory,
#   cpus and pids (all three hard limits), outside the shared client-data
#   slice (client-data.nix).
{
  # One hostname per origin under this domain, each with its own DNS
  # record in NicolaiSchmid/dns (no wildcard).
  baseDomain = "convex.modusservice.com";
  deployments = {
    june-dev = {
      cloudPort = 13210;
      sitePort = 13211;
      memory = "768m";
      cpus = "1";
    };
    june-prod = {
      cloudPort = 13220;
      sitePort = 13221;
      # The production bundle and stopped-checkpoint recovery passed under
      # these bounds on 2026-11-03. 8G since 2026-11-05: at 4G the backend sat
      # at its ceiling within hours of a restart (4.2 GB anonymous, 6,756 hits
      # on memory.max), every function ran into Convex's 1 s limit and
      # junepartner.com's chat failed. Atlas gave up 5 GiB for it (libvirt.nix).
      memory = "8G";
      cpus = "2";
      pids = 256;
      slice = "juneprod";
      # The callback transport fix (patches/convex-callback-headers): source
      # 46334ae, build 41885580642, isolated acceptance 41891541466,
      # digest-preserving publication 41893296684. Only by registry digest
      # (scripts/june-callback-build/README.md).
      image = "ghcr.io/nicolaischmid/june-convex-backend@sha256:fc6f1b18d8e4ed81b9f77dffe131bc58c333c85557f51501324418fd6a2eb2bb";
      environment = {
        # Headroom for reactive sidebar queries under shared-host load.
        DATABASE_UDF_USER_TIMEOUT_SECONDS = "5";
        # User ceiling 1800s; local executor has another 5s of system overhead.
        NODE_ACTION_USER_TIMEOUT_SECS = "1800";
        # Keep the HTTP request envelope above the 1805s executor deadline.
        HTTP_SERVER_TIMEOUT_SECONDS = "2100";
      };
    };
    # The MODUS AI token gateway. 1536m since 2026-11-09: its Node actions
    # read PDFs and decode scanned pages for OCR in this container, and one
    # 12-page 300 dpi scan took gateway-dev past 512m (modus repository,
    # .plans/2026-11-09-gateway-file-parser.md).
    modus-gateway-dev = {
      cloudPort = 13230;
      sitePort = 13231;
      memory = "1536m";
      cpus = "0.5";
    };
    modus-gateway-prod = {
      cloudPort = 13240;
      sitePort = 13241;
      memory = "1536m";
      cpus = "1";
    };
    # modus-dev and modus-prod (13250-13261) were retired empty on 2026-11-05:
    # the MODUS site's backend moved into June's (modus repository,
    # .plans/2026-11-02-modus-shared-convex.md). Their exports stay on black
    # in backups/modus-retirement-20261105.
  };
}
