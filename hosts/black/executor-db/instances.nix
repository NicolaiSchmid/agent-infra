# The self-hosted libSQL servers (sqld) for June's executor database, the
# Executor SDK's integration registry (connections, tool catalogues, OAuth
# sessions; secrets stay in Convex). Read by executor-db.nix (one server per
# entry) and convex.nix (which Convex backend joins which server's network).
# Operations: runbooks/black-executor-db.md.
#
# Per entry:
# - convex: the Convex deployment (convex/deployments.nix) that uses it; only
#   that backend joins the server's private network;
# - port: loopback port for the backup and health timers and SSH tunnels;
# - memory: hard limit of the container (the data is a few MB; sqld idles
#   near 10 MB and peaked near 60 MB replaying a 25 MB dump).
{
  instances = {
    june-prod = {
      convex = "june-prod";
      port = 13280;
      memory = "256m";
    };
    june-dev = {
      convex = "june-dev";
      port = 13281;
      memory = "128m";
    };
  };
}
