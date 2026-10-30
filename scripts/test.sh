#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
crystal tool format --check src spec examples
crystal run lib/ameba/bin/ameba.cr -- --no-color
sh lib/pod5/scripts/with_native.sh crystal spec
python3 scripts/integration.py 3000
python3 scripts/edge_cases.py
python3 scripts/slow_consumer.py
python3 scripts/test_formats.py
