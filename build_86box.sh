#!/bin/bash
# Build the 86Box fork (submodule 86box: 86Box master + test control FIFO, POST log, fault injection, RTL8139 boot ROM
# socket, SLiRP TFTP, and the machines of every board here). Output: build/86box/out/src/86Box (SDL frontend, tests);
# GUI=1 also builds build/86box/out-qt/src/86Box (Qt6 GUI, run_86box.sh).
set -euo pipefail
nb=$(dirname "$(readlink -f "$0")")
src=$nb/86box
out=$nb/build/86box
[ -f "$src/CMakeLists.txt" ] || "$nb/fetch_sources.sh" > /dev/null
build() {  # build dir, cmake options
  [ -f "$out/$1/build.ninja" ] || cmake -S "$src" -B "$out/$1" -G Ninja -DCMAKE_BUILD_TYPE=Release -DRELEASE=ON \
    -DDISCORD=OFF -DMUNT=OFF -DSOUNDCANVAS=OFF -DFLUIDSYNTH=OFF -DRTMIDI=OFF -DOPENAL=OFF "${@:2}" > /dev/null
  ninja -C "$out/$1" > "$out/$1/build.log" 2>&1 || { tail -30 "$out/$1/build.log"; echo "86BOX BUILD FAILED" >&2; exit 1; }
}
build out -DQT=OFF
[ -z "${GUI:-}" ] || build out-qt -DQT=ON -DUSE_QT6=ON
echo "$out/out/src/86Box"
