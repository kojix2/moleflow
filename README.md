# Moleflow

<img width="400" height="200" alt="moleflow" src="https://github.com/user-attachments/assets/045f265b-315c-442b-9f2b-d5bbd5a56263" />

[![Test](https://github.com/kojix2/moleflow/actions/workflows/test.yml/badge.svg)](https://github.com/kojix2/moleflow/actions/workflows/test.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fmoleflow%2Flines)](https://tokei.kojix2.net/github/kojix2/moleflow)

MinKNOW Read Until simulator in Crystal. Stream synthetic or replayed nanopore
signals over gRPC, handle unblock/stop-data actions, or generate signals offline.

Application lockfiles are not committed. The build script runs `shards update`
to follow the declared dependency branches; locally generated `shard.lock` files
are ignored by Git.

## Build

Requires Crystal >= 1.22, Shards and C++20 build tools. From the repository root:

```sh
# Ubuntu
sudo apt-get install libgtk-3-dev build-essential pkg-config libnghttp2-dev libssl-dev libyaml-dev curl tar unzip patch
# macOS: install Xcode Command Line Tools, then:
brew install pkg-config libnghttp2 openssl@3 libyaml
export PKG_CONFIG_PATH="$(brew --prefix libnghttp2)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix libyaml)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$(brew --prefix libnghttp2)/lib:$(brew --prefix openssl@3)/lib:$(brew --prefix libyaml)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

Run the commands for your OS, then `sh scripts/build.sh`. This updates runtime
dependencies from `main`, installs native POD5 and builds `bin/moleflow`,
`bin/moleflow-pod5` and `bin/moleflow-gui`. Native downloads support Linux
x86_64/ARM64 and macOS 14+ ARM64.

## Run

```sh
bin/moleflow --validate -c examples/r10.json
bin/moleflow -c examples/r10.json
# Offline signal generation:
bin/moleflow --simulate -c examples/r10.json
```

Run live and offline modes separately. By default the Manager listens on port
9502 and the position service on 10001, without TLS. A live run starts when a
client sets up `get_live_reads`; restart the process for a new session.
For a client example: `crystal run examples/client.cr -- localhost:10001`.

Edit [examples/r10.json](examples/r10.json) for your inputs. Common settings are
`channels`, `workers`, `duration_seconds`, `chunk_ms`, `seed` and `output`.
Paths are relative to the working directory. See [Config](src/moleflow/config.cr)
and [API support](docs/API.md) for defaults, TLS and protocol limits.

## GUI

```sh
bin/moleflow-gui -c examples/r10.json
```

Edit common settings in the form or all settings in the JSON tab. The native
toolbar uses [Radix icons](https://github.com/kojix2/icon-radix) for open/save,
settings, validation and start/stop; the log tab shows output. Relative paths use
the displayed working directory. The GUI launches the sibling `moleflow` CLI;
`--cli=PATH` selects another executable. Choose serve or offline generation;
configure multiple samples, raw replay and TLS in the JSON tab.
Ubuntu requires GTK 3; macOS uses native controls. GUI smoke tests:
`sh scripts/test-gui.sh` (Linux also needs `xvfb` and `xauth`).

On macOS, the build and GUI test scripts use `-Dwithout_mt` for the GUI as a
workaround for Crystal execution contexts moving fibers off AppKit's required
main thread. Manual GUI builds need the same flag. The CLI binaries retain
execution contexts for their worker pools.

## Record and replay

Set `output` to a new directory to record metadata and raw ADC signals.
FASTA inputs synthesize signals; raw little-endian int16 inputs use `replay: true`.

```sh
sh scripts/pod5.sh convert output run.pod5
sh scripts/pod5.sh prepare real.pod5 replay --limit=1000
bin/moleflow -c replay/replay.json
```

POD5 preparation normalizes calibration and rejects clipping or mixed sample
rates. Use new destination paths. FAST5 is not supported.

## Test

After building, install the independent Python client's test dependencies:

```sh
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements-test.txt
sh scripts/test.sh
```

The suite covers gRPC/TLS, 3,000 channels, slow consumers and POD5 interoperability.
CI runs on Ubuntu and macOS. Synthetic signal realism and Dorado basecalling
accuracy remain unvalidated; use real signal replay for downstream testing.
Interactive timing is not reproducible from the random seed alone.

See [validation](docs/VALIDATION.md) and [architecture](docs/ARCHITECTURE.md).
Licensed under [MPL-2.0](LICENSE). The bundled R10 model and adapter derive from
[Icarust](https://github.com/LooseLab/Icarust); see [NOTICE](NOTICE) for provenance.
