# The production bundle and stopped-checkpoint recovery passed under these
# bounds on 2026-11-03. Keep June outside the shared demo slice (client-data.nix).
# 8G since 2026-11-05: at 4G the backend sat at its ceiling within hours of a
# restart (4.2 GB anonymous, 6,756 hits on memory.max), every function ran
# into Convex's 1 s limit and junepartner.com's chat failed. Atlas gave up
# 5 GiB for it (libvirt.nix).
{
  memory = "8G";
  cpus = 2;
  pids = 256;
  slice = "juneprod";
}
