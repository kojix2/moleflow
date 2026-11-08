#!/bin/sh
set -eu
export NANOPORE_GUI_TESTS=1
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Linux ]; then
  GDK_BACKEND=x11 xvfb-run -a crystal spec spec/gui/native_spec.cr
elif [ "$(uname -s)" = Darwin ]; then
  # Match the macOS GUI build workaround: Crystal 1.21+ execution contexts can
  # move the GUI fiber off the OS main thread during I/O. AppKit updates and
  # uiUninit then crash. Keep the legacy scheduler until main-thread affinity
  # is guaranteed for the full GUI lifetime, including teardown.
  crystal spec spec/gui/native_spec.cr -Dwithout_mt
else
  crystal spec spec/gui/native_spec.cr
fi
