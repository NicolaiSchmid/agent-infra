# The production bundle and stopped-checkpoint recovery passed under these
# bounds on 2026-11-03. Keep June outside the shared 3 GiB demo slice.
{
  memory = "4G";
  cpus = 2;
  pids = 256;
  slice = "juneprod";
}
