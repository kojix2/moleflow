# Moleflow

A bounded-memory, multithreaded MinKNOW Read Until simulator written in Crystal.
Version 0.1.2.

[Code organization](docs/ARCHITECTURE.md).

It provides live gRPC signal streaming, per-read unblock and stop-further-data,
TLS, channel selection, signal calibration, deterministic offline simulation,
on-demand FASTA-to-signal synthesis, circular molecules, weighted samples, and
real-signal replay. The package includes an R10 DNA k-mer current model and an
optional adapter signal derived from Icarust.

## Quick start

Run commands from the project root. Build from source using Crystal >= 1.22,
Shards and the system dependencies listed below.

```sh
sh scripts/build.sh
./bin/moleflow --validate -c examples/r10.json
./bin/moleflow -c examples/r10.json
```

Manager: `localhost:9502`; sequencing position: `localhost:10001`.
No TLS by default for local development. The clock starts with the first
`get_live_reads` setup. One simulation session is accepted per process; restart
for an independent experiment. The process remains available for metadata after
the run. Use Ctrl-C to stop it.

```sh
# System dependencies: libnghttp2, OpenSSL, pkg-config, compiler/linker
# Debian/Ubuntu: apt install build-essential pkg-config libnghttp2-dev libssl-dev libyaml-dev
# Fast, deterministic offline simulation
./bin/moleflow --simulate -c examples/demo.json
# Tests with an independent Python client
python3 -m pip install -r requirements-test.txt
sh scripts/test.sh
```

Dependencies track the latest available versions without commit pins in
`shard.yml`; `shard.lock` records the resolved versions for reproducible builds.
Run `shards update` to refresh them. The build script installs the Crystal
dependencies and the native POD5 library.
Native POD5 setup requires a C++20 compiler, curl, tar, unzip and patch; see
[pod5.cr](https://github.com/kojix2/pod5.cr) for platform requirements. The gRPC streaming and linker fixes are
included upstream; no patch application is needed.
The MinKNOW dependency also includes regenerated Google protobuf types;
no application-level Float compatibility extensions are needed.

## Configuration

JSON configuration, examples in `examples/`. Paths are relative to the working
directory. Every sample requires `path`; FASTA and raw little-endian int16 signal
are supported. `replay: true` selects raw signal. Multiple FASTA records are
selected proportionally to length within a sample. `weight` is a positive
relative probability of selecting a sample, not an automatically inferred copy
number. `circular` wraps both reads and k-mer windows across the sequence end.
Both DNA strands are sampled.

Important settings (all except samples have defaults):

| Setting | Default | Meaning |
|---|---:|---|
| channels | 512 | Number of simulated pores, 1..65535 |
| workers | 4 | CPU workers; at most one per pore |
| sample_rate | 5000 | Samples per second |
| sequencing_speed | 400 | Bases per second, may be fractional |
| chunk_ms | 400 | Signal delivery tick interval |
| duration_seconds | 60 | Simulated run duration |
| seed | 12345 | Reproducible pore and signal seeds |
| mean_read_length | 10000 | Mean DNA length before linear-edge truncation |
| read_length_sigma | 0.5 | Lognormal standard deviation in log space |
| max_read_bases | 1000000 | Maximum drawn molecule length |
| working_fraction | 1 | Initially active pore fraction |
| death_probability | 0 | Probability of pore loss after each read |
| reacquire_seconds | 0.2 | Mean exponential reacquisition delay |
| noise_pa | 1 | Gaussian per-sample noise, pA |
| scale / offset | 0.1462070643901825 / -243 | pA = (ADC + offset) × scale |
| model | null | Complete k-mer to mean-pA table (k <= 9) |
| adapter_signal | null | Optional raw int16 LE prefix; ignored for replay |
| output | null | New output directory; existing directory is refused |
| max_reference_bytes | 4000000000 | Total reference base limit |
| max_chunk_samples | 50000 | Catch-up/partial-chunk cap; excessive lag aborts |
| max_batch_channels | 24 | Maximum channels in a response |
| stream_queue | 32 | Bounded application response queue |
| host | 127.0.0.1 | Bind address |
| manager_port / position_port | 9502 / 10001 | gRPC ports |
| device_id | MOLEFLOW | Manager flow-cell position name |
| tls_cert / tls_key | null | PEM paths; provide both for TLS |

Without a current model, a **toy model** is used and a warning is printed.
Use `examples/r10.json` for the bundled research model. The table must enumerate
all A/C/G/T k-mers of one length. Non-ACGT reference bases are replaced
reproducibly per molecule without removing positions. Replay is streamed from
files and does not use the synthetic model, adapter, or configured read length.

## Output and replay

Set `output` to a new directory, then run online or offline. It contains:

- `config.json`: complete effective configuration.
- `reads.jsonl`: terminal read records, reference origin, orientation, seed,
  sample count and end reason. `origin` is a zero-based coordinate of the first
  base; `reverse` means traversal toward decreasing coordinates.
- `signal/UUID.i16`: per-read raw ADC samples in little-endian int16, including
  the tail generated before unblock. No full read signal is retained in RAM.

`stop_further_data` stops client delivery, while sequencing and output continue.
`unblock` finishes the current read and adds its specified duration to the pore's
reacquisition delay. A stale read ID never acts on a successor. If an unblock
exceeds the configured maximum read age, it returns FAILED_READ_TOO_LONG and
stops further client data for that read, following the protocol definition.

```sh
sh scripts/pod5.sh convert output run.pod5
sh scripts/pod5.sh prepare real.pod5 replay --limit=1000
./bin/moleflow -c replay/replay.json
```

POD5 conversion runs outside the server, one completed read at a time.
The Crystal tool uses pod5.cr and the official native POD5 library; Python is
only used by independent interoperability tests. FAST5 is not supported.
Conversion holds one full read in memory; ADC I/O uses 64 KiB blocks. Replay preparation converts different
per-read calibrations to one common ADC calibration; it rejects clipping and
mixed sampling rates. This conversion may introduce quantization differences.
Raw `.i16` replay itself is byte-exact. Output file count grows with the number of
reads; choose sufficient disk space or disable output for throughput tests.

## Protocol support and limits

See [docs/API.md](docs/API.md) for implemented RPCs and deliberate boundaries.
Signal responses are bounded to approximately 2 MiB plus protobuf metadata.
The transport has at most eight queued messages per stream; it releases sent
buffers and correctly handles messages spanning multiple HTTP/2 DATA frames.
Slow consumers cause an explicit RESOURCE_EXHAUSTED error rather than an
unbounded queue. Disk output uses a separate execution context and four queued
ticks; a stalled disk terminates the run. Queues are bounded, not hard-real-time.

The signal model uses fixed translocation speed and independent Gaussian noise.
It does not model variable dwell times, methylation, detailed pore drift, motor
chemistry, duplex reads, or barcode chemistry. The bundled prefix is reused.
R10 signal realism and current Dorado basecalling accuracy are **not validated**.
Use real-signal replay to test a basecaller pipeline before drawing biological
conclusions from synthetic signals.

## Reproducibility

Pore state and random generators are owned by individual workers. Signal noise is
a pure function of the read seed and relative sample offset. Changing worker
count or chunk boundaries does not change the signal of an already chosen read.
Offline simulation uses integer sample time and is repeatable. Live runs use a
monotonic clock; client and scheduling delays change action times and therefore
subsequent read histories. Seed alone cannot make an interactive run identical.

Reference storage is about one byte per base plus parser overhead, not 12× or
more expanded signal. The FASTA loader uses transient copies; allow additional
peak memory during loading. Memory still scales with references, pore count,
configured chunk limits and queue capacities. Only small references were used
in the included benchmark; the measured RSS is not a human-genome estimate.

## Validation

[docs/VALIDATION.md](docs/VALIDATION.md) records actual checks and their limits.
[docs/AUDIT.md](docs/AUDIT.md) records the initial commit audit and corrections.
Run `python3 scripts/stress.py 3000 20` for a local load test. The tests use the
independent Python `minknow-api` package to avoid relying solely on matching
Crystal client/server behavior. No Rust-vs-Crystal performance claim is made.

License: MPL-2.0. See [NOTICE](NOTICE) for model and dependency provenance.

A minimal Crystal receiving/unblocking client is included:

```sh
# With examples/demo.json running in another terminal
crystal run examples/client.cr -- localhost:10001
```

## Static analysis

`scripts/test.sh` checks formatting and runs the Ameba development
dependency before the tests. To run Ameba separately:

```sh
crystal run lib/ameba/bin/ameba.cr -- --no-color
```

Its scope is application sources, specs and examples. Dependency sources and
generated code are outside its scope.

## Working with local pod5.cr changes

Clone pod5.cr beside this checkout and create `shard.override.yml`:

```yaml
dependencies:
  pod5:
    path: ../pod5.cr
```

Run `sh scripts/build.sh` afterwards. This ignored override tests unpublished
pod5.cr changes without changing the remote dependency. The current upstream
version already includes the writer optimization that removes an extra signal
copy. Never mutate a signal concurrently with `Writer#add`.
