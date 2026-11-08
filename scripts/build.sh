#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
shards update
prefix=${POD5_NATIVE_PREFIX:-"$PWD/lib/pod5/vendor/pod5"}
if [ ! -f "$prefix/lib/libpod5_cr_compat.so" ] && [ ! -f "$prefix/lib/libpod5_cr_compat.dylib" ]; then
  sh lib/pod5/scripts/install_native.sh
fi
if [ "$(uname -s)" = Darwin ]; then
  sh lib/pod5/scripts/with_native.sh shards build moleflow moleflow-pod5 --release
  # Workaround: Crystal 1.21+ execution contexts can migrate fibers off the OS
  # main thread, even with parallelism 1. AppKit requires GUI operations and
  # uiUninit on the main thread. Use the legacy scheduler for the GUI until it
  # can guarantee that affinity; CLI worker contexts must stay enabled.
  sh lib/pod5/scripts/with_native.sh shards build moleflow-gui --release -Dwithout_mt
else
  sh lib/pod5/scripts/with_native.sh shards build --release
fi
