"""Targeted safety tests: no actual filesystem defragmentation is performed."""
import os
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "hosts/black/vm-reclaim.sh").read_text()
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    binaries = root / "bin"
    binaries.mkdir()
    images = [root / "state.raw", root / "root.raw"]
    for image in images:
        image.touch()
    script = root / "reclaim.sh"
    script.write_text(source.replace("/var/lib/libvirt/images/atlas-state.raw", str(images[0]))
                     .replace("/var/lib/libvirt/images/atlas-root.raw", str(images[1])))
    mocks = {
        "df": 'printf "Avail\\n%s\\n" "$FREE_BYTES"',
        "lsattr": 'echo "${ATTRIBUTES:---------------C------} image"',
        "stat": 'echo 17179869184',
        "btrfs": '''case "$1 $2" in
"filesystem du") printf 'Total Exclusive Shared Filename\\n1024 %s %s image\\n' "${EXCLUSIVE:-1024}" "${SHARED:-0}" ;;
"filesystem defragment") echo "$*" >> "$OPERATIONS" ;;
"filesystem sync") : ;;
*) exit 99 ;;
esac''',
    }
    for name, text in mocks.items():
        path = binaries / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + text + "\n")
        path.chmod(0o755)

    def run(name, expected, **values):
        state = root / name
        operations = root / (name + "-operations")
        environment = dict(os.environ, PATH=str(binaries) + ":" + os.environ["PATH"],
                           STATE_DIRECTORY=str(state), OPERATIONS=str(operations),
                           FREE_BYTES="53687091200", **values)
        result = subprocess.run(["bash", str(script)], env=environment, capture_output=True, text=True)
        assert result.returncode == expected, (name, result.stdout, result.stderr)
        return state, operations

    mocks["df"] = 'printf "Avail\\n%s\\n" "${FREE_OVERRIDE:-$FREE_BYTES}"'
    (binaries / "df").write_text("#!/usr/bin/env bash\nset -eu\n" + mocks["df"] + "\n")
    _, calls = run("enough-space", 0, FREE_OVERRIDE="214748364800")
    assert not calls.exists()
    _, calls = run("too-full", 1, FREE_OVERRIDE="1073741824")
    assert not calls.exists()
    _, calls = run("shared", 1, EXCLUSIVE="512", SHARED="512")
    assert not calls.exists()
    _, calls = run("cow", 1, ATTRIBUTES="----------------------")
    assert not calls.exists()
    state, calls = run("bounded", 0)
    assert len(calls.read_text().splitlines()) == 8
    assert (state / "cursor").read_text().strip() == "0 8589934592"
    # Subsequent runs continue instead of rewriting the start indefinitely.
    run("bounded", 0)
    assert (state / "cursor").read_text().strip() == "0 17179869184"
print("VM reclaim safety checks passed")
