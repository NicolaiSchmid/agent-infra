#!/usr/bin/env python3
"""Add admitted resource limits and workspace checks to the pinned recipe."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
p = root / 'Dockerfile.callback'
s = p.read_text()
assert s.startswith('# syntax=docker/dockerfile:1-labs\n')
s = s.replace('# syntax=docker/dockerfile:1-labs', '# syntax=docker/dockerfile@sha256:daa72495a6b3ca6afb204e3f92542569f88f004588bd6082e81c6dfc6c3df463', 1)
needle = ' AS build\n'
assert s.count(needle) == 1
s = s.replace(needle, needle + 'ENV CARGO_BUILD_JOBS=12\n')
needle = 'COPY . .\n'
assert s.count(needle) == 1
s = s.replace(needle, needle + '''# Frozen install above checks importer/lock consistency. Upstream's documented
# format-js/lint-js recipes are absent at this source revision; use its actual
# formatter and filtered TypeScript build, without claiming a missing lint ran.
RUN scripts/node_modules/.bin/dprint check npm-packages/node-executor/src/syscalls.ts npm-packages/node-executor/src/callbackTransport.ts npm-packages/node-executor/src/callbackTransport.test.ts npm-packages/node-executor/package.json
RUN just turbo run build --filter=node-executor...
RUN cd npm-packages/node-executor && ../../scripts/node_modules/.bin/pnpm exec vitest run src/callbackTransport.test.ts
RUN sha256sum npm-packages/node-executor/dist/local.cjs && node --version && cargo --version && rustc --version
''')
p.write_text(s)
manifest = root / 'callback-build-inputs.json'
x = json.loads(manifest.read_text())
x['dockerfile_sha256'] = hashlib.sha256(s.encode()).hexdigest()
x['cargo_build_jobs'] = 12
manifest.write_text(json.dumps(x, indent=2) + '\n')
