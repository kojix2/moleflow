#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
shards install
prefix=${POD5_NATIVE_PREFIX:-"$PWD/lib/pod5/vendor/pod5"}
if [ ! -f "$prefix/lib/libpod5_cr_compat.so" ] && [ ! -f "$prefix/lib/libpod5_cr_compat.dylib" ]; then
  sh lib/pod5/scripts/install_native.sh
fi
sh lib/pod5/scripts/with_native.sh shards build --release
