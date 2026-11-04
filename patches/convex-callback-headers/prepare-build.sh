#!/usr/bin/env bash
# Prepare sources only. Does not invoke Docker, build, push, or deploy.
set -euo pipefail
source_rev=bb31399c8704ceb6c19003936f6e144375b2c3bc
base_image=ghcr.io/convex/convex-backend@sha256:207cf95def42f01614b6e3af0af5c20d0dcaa5ff2adf258ee7bc9555576644fa
patch_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_dir=${1:?usage: prepare-build.sh NEW_DIRECTORY BUILDER_IMAGE_AT_SHA256}
builder_image=${2:?resolve and review cargo-chef builder digest before preparing}
[[ "$builder_image" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] || { echo 'builder must be digest-pinned' >&2; exit 1; }
[[ ! -e "$build_dir" ]] || { echo 'destination must not exist' >&2; exit 1; }
mkdir -p -- "$build_dir"
git -C "$build_dir" init -q
git -C "$build_dir" fetch --depth=1 https://github.com/convex/convex-backend.git "$source_rev"
git -C "$build_dir" checkout -q --detach FETCH_HEAD
[[ $(git -C "$build_dir" rev-parse HEAD) == "$source_rev" ]]
git -C "$build_dir" apply --check "$patch_dir/fix.patch"
git -C "$build_dir" apply "$patch_dir/fix.patch"
python3 - "$build_dir" "$builder_image" "$base_image" "$patch_dir/fix.patch" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root, builder, base, patch = sys.argv[1:]
root = Path(root)
original = (root / 'self-hosted/docker-build/Dockerfile.backend').read_text()
# Keep upstream's JS/Rust build stages; freeze the two cargo-chef stage bases.
head = original.split('# Final stage:', 1)[0]
if head.count('lukemathwalker/cargo-chef:latest-rust-1') != 2:
    raise RuntimeError('unexpected upstream builder stages')
head = head.replace('lukemathwalker/cargo-chef:latest-rust-1', builder)
patch_hash = hashlib.sha256(Path(patch).read_bytes()).hexdigest()
# Keep the exact existing OS, Node, entrypoint and key generator. Only the
# backend binary (which embeds local.cjs) is replaced. No extracted JS overlay.
tail = f'''FROM {base}
COPY --from=build --chmod=744 /convex/convex-local-backend /convex/convex-local-backend
LABEL io.convex.upstream.revision="bb31399c8704ceb6c19003936f6e144375b2c3bc" \\
      io.convex.callback.patch.sha256="{patch_hash}"
'''
(root / 'Dockerfile.callback').write_text(head + tail)
(root / 'callback-build-inputs.json').write_text(json.dumps({
    'upstream': 'bb31399c8704ceb6c19003936f6e144375b2c3bc',
    'patch_sha256': patch_hash, 'builder': builder, 'runtime_base': base,
    'dockerfile_sha256': hashlib.sha256((head + tail).encode()).hexdigest(),
}, indent=2) + '\n')
PY
printf 'Prepared sources at %s. Build not started; resource admission is required.\n' "$build_dir"
