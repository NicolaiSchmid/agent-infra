# The self-hosted Convex deployments on black, read by convex.nix (one
# backend per entry) and routes.nix (which projects may route to which
# deployment). Adding a deployment: runbooks/black-client-data-demo.md.
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
      memory = "1g";
      cpus = "1.5";
    };
    # The MODUS AI token gateway.
    modus-gateway-dev = {
      cloudPort = 13230;
      sitePort = 13231;
      memory = "512m";
      cpus = "0.5";
    };
    modus-gateway-prod = {
      cloudPort = 13240;
      sitePort = 13241;
      memory = "768m";
      cpus = "1";
    };
    # MODUS itself: contracts, consent and billing (apps/site/convex in the
    # modus repository). Holds firm contacts, never client data.
    modus-dev = {
      cloudPort = 13250;
      sitePort = 13251;
      memory = "512m";
      cpus = "0.5";
    };
    modus-prod = {
      cloudPort = 13260;
      sitePort = 13261;
      memory = "768m";
      cpus = "1";
    };
  };
}
