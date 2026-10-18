# Docker storage and memory on atlas.
#
# Images, containers, volumes and build cache (the managed containerd keeps
# its snapshots under data-root too) live on the 1 TB state disk. On
# /var/lib/docker they filled the 118G root disk twice on 2026-10-17, when CI
# and agents' test stacks pulled ~15 GB of images and left ~80 volumes in an
# hour. Moving data-root needs a planned stop of Docker; see
# runbooks/atlas-docker.md.
#
# Containers run in atlas-containers.slice instead of system.slice. When atlas
# ran out of memory on 2026-10-18, a test stack's mongod held 10.5G with no
# limit; now test stacks are throttled and OOM-killed among themselves. Hermes
# keeps running in system.slice (configuration.nix).
{
  virtualisation.docker.daemon.settings = {
    data-root = "/srv/agents-state/docker";
    cgroup-parent = "atlas-containers.slice";
  };

  systemd.tmpfiles.rules = ["d /srv/agents-state/docker 0710 root root -"];

  systemd.slices.atlas-containers = {
    description = "Docker containers (agents' test stacks, sandboxes)";
    sliceConfig = {
      MemoryHigh = "12G";
      MemoryMax = "16G";
    };
  };
}
