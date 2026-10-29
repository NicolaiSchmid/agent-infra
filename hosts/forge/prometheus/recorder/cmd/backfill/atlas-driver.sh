#!/bin/sh
# Resumable atlas backfill: one chunk per shard, a done/ marker per chunk,
# stop at the first chunk that doesn't fully land.
# Recover a failed chunk k:
#   DELETE FROM prometheus.requests WHERE machine='atlas' AND request_headers['x-backfill-chunk']='k/16'
# then start this script again; finished chunks are skipped.
D=/var/lib/prometheus-backfill
N=16
mkdir -p $D/done $D/logs
for k in $(seq 0 $((N-1))); do
  [ -f $D/done/$k ] && continue
  echo "$(date -Is) chunk $k/$N start" >> $D/progress.log
  nice -n 10 $D/backfill -machine atlas -client-ip 100.122.138.66 \
    -claude-dir /srv/agents-state/nicolai/.claude/projects \
    -codex-dir /srv/agents-state/nicolai/.codex/sessions \
    -t3-dir /srv/agents-state/t3code/userdata \
    -until 2026-10-29T08:53:00Z -workers 4 \
    -clickhouse-password-file $D/pw -shard $k -shards $N > $D/logs/$k.log 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "$(date -Is) chunk $k/$N FAILED rc=$rc (see logs/$k.log)" >> $D/progress.log
    exit 1
  fi
  touch $D/done/$k
  echo "$(date -Is) chunk $k/$N done: $(grep -E '^calls  ' $D/logs/$k.log | awk '{print $2}') calls" >> $D/progress.log
done
echo "$(date -Is) all $N chunks done" >> $D/progress.log
