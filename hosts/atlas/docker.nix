# Docker storage and memory on atlas.
#
# Images, containers, volumes and build cache (the managed containerd keeps
# its snapshots under data-root too) live on the 1 TB state disk. On
# /var/lib/docker they filled the 118G root disk twice on 2026-10-17, when CI
# and agents' test stacks pulled ~15 GB of images and left ~80 volumes in an
# hour. Changing these settings restarts Docker on switch, and moving
# data-root needs the copy first; see runbooks/atlas-docker.md.
#
# Containers run in atlas-containers.slice instead of system.slice. When atlas
# ran out of memory on 2026-10-18, a test stack's mongod held 10.5G with no
# limit; now test stacks are throttled and OOM-killed among themselves. The
# slice nests in atlas.slice next to the CI runners, which carries the CPU/IO
# weight of 20 and the shared ceiling (priorities.nix).
# The Hermes container runs in system-hermes.slice instead, where its weight
# of 1000 applies to the gateway itself rather than only to the `docker run`
# client in hermes.service. The system- prefix is what nests it in
# system.slice; it is not an atlas-* name on purpose.
{
  virtualisation.docker.daemon.settings = {
    data-root = "/srv/agents-state/docker";
    cgroup-parent = "atlas-containers.slice";
  };

  systemd.services.docker.unitConfig.RequiresMountsFor = ["/srv/agents-state"];

  systemd.slices.atlas-containers = {
    description = "Docker containers (agents' test stacks, sandboxes)";
    sliceConfig = {
      MemoryHigh = "12G";
      MemoryMax = "16G";
    };
  };

  systemd.slices.system-hermes = {
    description = "Hermes gateway container";
    sliceConfig = {
      CPUWeight = 1000;
      IOWeight = 1000;
    };
  };
}
