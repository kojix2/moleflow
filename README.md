# Moleflow

A multithreaded MinKNOW Read Until simulator written in Crystal. Stream
synthetic or replayed nanopore signals over gRPC, test unblock/stop-data
clients, or generate signals offline. Includes an R10 DNA current model.

## Build

Requires Crystal >= 1.22, Shards, a C++20 compiler, curl, tar, unzip and patch.
Run all commands from the repository root. Install dependencies for your OS:

```sh
# Ubuntu
sudo apt-get install -y build-essential pkg-config libnghttp2-dev libssl-dev libyaml-dev curl unzip patch

# macOS (Apple Silicon; requires Xcode Command Line Tools)
brew install pkg-config libnghttp2 openssl@3 libyaml
export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix libnghttp2)/lib/pkgconfig:$(brew --prefix libyaml)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$(brew --prefix libnghttp2)/lib:$(brew --prefix openssl@3)/lib:$(brew --prefix libyaml)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

Then build:

```sh
sh scripts/build.sh
```

This installs Crystal dependencies and the native POD5 library, then builds
`bin/moleflow` and `bin/moleflow-pod5`. Native downloads support Linux x86_64,
Linux ARM64 and macOS ARM64; see [pod5.cr](https://github.com/kojix2/pod5.cr)
for other platforms. Python is needed only for tests.

Dependencies have no commit pins in [shard.yml](shard.yml).
[shard.lock](shard.lock) records resolved versions; use `shards update` to
refresh them.

## Run

```sh
./bin/moleflow --validate -c examples/r10.json
./bin/moleflow -c examples/r10.json
```

The manager listens on `localhost:9502` and the sequencing position on
`localhost:10001`, without TLS by default. The simulation starts when a client
sets up `get_live_reads`. Restart the process for a new session; use Ctrl-C to
stop it.

An example receiving/unblocking client is available:

```sh
crystal run examples/client.cr -- localhost:10001
```

For deterministic offline simulation:

```sh
./bin/moleflow --simulate -c examples/r10.json
```

## Configure

Start with [examples/r10.json](examples/r10.json). Paths are relative to the
working directory. Common settings:

| Setting | Default | Purpose |
|---|---:|---|
| `samples` | Required | Input paths with optional `weight`, `circular`, `replay` |
| `channels` / `workers` | 512 / 4 | Pores and CPU workers |
| `duration_seconds` | 60 | Run duration |
| `sample_rate` / `sequencing_speed` | 5000 / 400 | Samples/sec and bases/sec |
| `chunk_ms` | 400 | Signal delivery interval |
| `mean_read_length` | 10000 | Mean drawn read length in bases |
| `seed` | 12345 | Simulation seed |
| `model` / `adapter_signal` | None | Current model and optional raw int16 prefix |
| `output` | None | New directory for read metadata and raw signals |
| `tls_cert` / `tls_key` | None | TLS PEM paths; provide both |

FASTA inputs generate synthetic signals. For raw little-endian int16 inputs,
set `replay: true` on the sample. Without a current model, synthetic inputs use
a toy model. See [src/moleflow/config.cr](src/moleflow/config.cr) for all
settings and validation rules.

## Record and Replay

Set `"output": "output"` in your configuration before running. The directory
must not already exist. Moleflow writes `config.json`, terminal read records
in `reads.jsonl`, and per-read ADC files in `signal/`. Both live and offline
runs can record output; `stop_further_data` stops delivery, not recording.

```sh
sh scripts/pod5.sh convert output run.pod5
sh scripts/pod5.sh prepare real.pod5 replay --limit=1000
./bin/moleflow -c replay/replay.json
```

POD5 conversion is separate from the server and holds one read in memory.
Replay preparation normalizes calibration and rejects clipping or mixed sample
rates. Use new destination paths. FAST5 is not supported.

## Test

After building:

```sh
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements-test.txt
sh scripts/test.sh
```

The suite checks Crystal formatting, Ameba, specs, gRPC/TLS, slow consumers and
POD5 interoperability with an independent Python client. GitHub Actions runs
it on Ubuntu and macOS.

## Limits and References

Synthetic signals use fixed translocation speed and Gaussian noise. Biological
signal realism and Dorado basecalling accuracy are not validated; use real
signal replay for downstream pipeline testing. Live interaction timing affects
results, so a seed alone does not reproduce an interactive run.

- [API support and protocol limits](docs/API.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Validation results and boundaries](docs/VALIDATION.md)
- [Audit history](docs/AUDIT.md)

## Acknowledgements

Moleflow was developed with [Icarust](https://github.com/LooseLab/Icarust) as a
reference and uses its R10 model and adapter signal. Thanks to its authors and
contributors. Moleflow does not reproduce Icarust's behavior exactly; see
[NOTICE](NOTICE) for provenance and details.

## License

Moleflow is licensed under [MPL-2.0](LICENSE). Bundled model provenance and
third-party license and redistribution notices are listed in [NOTICE](NOTICE).
