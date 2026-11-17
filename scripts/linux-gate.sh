#!/usr/bin/env bash
#
# The gate on Linux, from a Mac: scripts/check.sh in the gate's image, on a fresh copy
# of the package.
#
#   scripts/linux-gate.sh            the working tree, as git lists it: what is tracked
#                                    and what is new, nothing that is ignored
#   scripts/linux-gate.sh <commit>   that commit's files
#
# The copy is new each time, in a folder of its own under .build/linux-gate, so that
# nothing an earlier run left is built or run, and its count of files is held against
# the listing. This script removes nothing: the copies stay where they are, each named
# by its time, for a person to delete (they are under .build, which git ignores).
#
# The build folder in the container is a named volume, which keeps the build from one
# run to the next and is a Linux file system. It matters which: the tests' files are in
# the container's own /tmp, but the gate's two-process step writes under the build
# folder, and a folder of the Mac's passed through to the container is a kind of file
# system on which the library reads no file through a memory map.
#
# THE CONFORMANCE SUITE. Its test of two processes is a step of the gate, which runs
# where the suite and its built writer are and says aloud where they are not. Where the
# suite is beside the package (../conformance) with its writer and its own reader built
# for Linux (out/linux/bin, which its linux-two-processes.sh builds on the Mac), the
# suite is mounted here to be read only, and the step is told where it and they are, so
# that on Linux too the port's reader is held on each of its six kinds against the
# original writing: Linux's files, maps and renames. Where they are not there, this
# says so, and so does the step, as on a runner that has the package alone. Nothing is
# written into the suite: the step's files go under the build folder.
#
# XITDB_LINUX_IMAGE and XITDB_LINUX_VOLUME name another image and another volume.

set -euo pipefail
cd "$(dirname "$0")/.."

image=${XITDB_LINUX_IMAGE:-swift:6.4}
volume=${XITDB_LINUX_VOLUME:-xitdb-linux-build}
suite=../conformance

command -v docker >/dev/null || {
    echo "error: no docker here, so the gate was not run on Linux"
    exit 1
}
[ $# -le 1 ] || {
    echo "usage: scripts/linux-gate.sh [commit]"
    exit 2
}

mkdir -p .build/linux-gate
copy=.build/linux-gate/$(date +%Y%m%d-%H%M%S)-$$
mkdir "$copy"
if [ $# -eq 1 ]; then
    what=$(git rev-parse --short "$1")
    git archive "$1" | tar -x -C "$copy"
    listed=$(git ls-tree -r --name-only "$1" | wc -l | tr -d ' ')
else
    what="the working tree at $(git rev-parse --short HEAD), with $(git status --short | wc -l | tr -d ' ') paths changed"
    git ls-files -co --exclude-standard | tar -c -T - | tar -x -C "$copy"
    listed=$(git ls-files -co --exclude-standard | wc -l | tr -d ' ')
fi
copied=$(find "$copy" \( -type f -o -type l \) | wc -l | tr -d ' ')
[ "$copied" -eq "$listed" ] || {
    echo "error: the copy has $copied files, and $listed are listed"
    exit 1
}
echo "a fresh copy of $what: $copied files of $listed listed, in $copy"

arguments=(-v "$PWD/$copy:/work" -v "$volume:/work/.build" -w /work)
if [ -f "$suite/two-processes.sh" ] && [ -x "$suite/out/linux/bin/two-processes" ] && [ -x "$suite/out/linux/bin/reader" ]; then
    arguments+=(
        -v "$(cd "$suite" && pwd):/conformance:ro"
        -e XITDB_CONFORMANCE=/conformance
        -e TWO_PROCESSES_DRIVER=/conformance/out/linux/bin/two-processes
        -e TWO_PROCESSES_OWN_READER=/conformance/out/linux/bin/reader
    )
    echo "the conformance suite at $suite is mounted to be read only, with its writer and reader built for Linux"
else
    echo "the conformance suite, or its writer and reader built for Linux, is not at $suite:"
    echo "  the gate's two-process step will say that it holds nothing"
fi

status=0
docker run --rm "${arguments[@]}" "$image" scripts/check.sh || status=$?
if [ "$status" -ne 0 ]; then
    echo "the gate failed on Linux with status $status"
fi
echo "the copy of the package it ran on is left in $copy"
exit "$status"
