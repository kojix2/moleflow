## Repository integration validation (2026-10-30)

Validated with mise-managed Crystal 1.22.1 on Linux x86_64 and native POD5
0.3.49, using upstream pod5.cr without bundled sources or a local override.
Dependencies have no commit pins in `shard.yml`; `shard.lock` records the
resolved versions. `shards update` selected pod5.cr `ab463468` and Ameba 1.7.0.

- Both release targets built with `sh scripts/build.sh`.
- `sh scripts/test.sh` passed formatting, Ameba (23 files), all 29 Crystal
  specs, plain/TLS gRPC, 3,000-channel integration, five edge-case scenarios,
  explicit slow-consumer termination, and independent Python POD5/replay
  interoperability for all 11 generated reads.
- Black and Ruff passed for the updated Python interoperability test.

The former Python conversion/preparation scripts are replaced by the Crystal
POD5 tool. FAST5 is no longer supported. Historical results below retain the
dependencies and functionality used in those earlier checks.

## POD5 integration update (2026-10-30)

Based on Moleflow `9f72ef9` and pod5.cr `5ba6014`, retaining the existing
initial-audit fixes. Checked on Linux x86_64 with Crystal 1.22.0 and native POD5
0.3.49, using the sibling pod5.cr checkout through `shard.override.yml`:

- Native POD5 installation from verified downloads and release builds succeeded.
- Moleflow: 29 specs passed, including 64 KiB ADC boundary and rollback tests.
- pod5.cr: 24 specs passed, including signal reuse before writer close and copying
  a lazy record whose source reader closes before the destination writer.
- Ameba: 23 application/spec/example files, zero failures. Formatting passed.
- Official Python POD5 interoperability: 11 reads; every ADC sample and replay
  calibration result matched the independent reader/NumPy calculations.
- gRPC integration: 32 channels, plain and TLS/calibrated streams, including
  unblock acknowledgements, passed.

These checks do not constitute a new throughput benchmark or GPU/real-device
validation. The writer avoids an extra Crystal signal copy; conversion still
holds a full read in memory. No new peak-RSS reduction is claimed.

> Historical results below include the former Python FAST5 support. Current
> conversion supports POD5 only; run `scripts/test.sh` for current checks.

# Validation record

Last functional validation: 2026-10-30. Crystal 1.22.0, Linux x86_64, OpenSSL 3,
nghttp2 system library. Python package versions are pinned in
`requirements-test.txt`. Results below are from this execution environment,
not comparative benchmarks against Rust Icarust.

## Functional tests

- 24 Crystal tests: chunk-independent signal, worker-count independence,
  per-molecule randomness, stale/duplicate unblock, maximum unblock age,
  stop-further-data, excessive lag, exact int16 replay, configuration/model
  validation, adapter crossing, reverse circular molecules, multiple short reads;
  plus aggregate catch-up bounds, backwards time, idempotent worker/output close,
  disk-close failure propagation, final-send failure propagation, dense model
  validation and adapter size boundaries. Initial-audit regressions additionally
  cover empty output paths, preservation of existing output, large finite sample
  weights, overflowing durations and bounded disk shutdown. Failure-path tests
  use injection; they do not simulate a physical disk failure.
- Independent Python MinKNOW client: plain and TLS bidirectional gRPC, ADC and
  calibrated Float32 payloads, continuous absolute sample coordinates, manager
  discovery, per-channel calibration, unblock acknowledgment, stale ID rejection,
  final output size and unblock reason.
- Five Python edge-case scenarios: minimum chunk length/channel range, stop data
  while recording continues, live setup update/NONE, invalid range, cancellation
  and graceful termination.
- Slow consumer: pause a 3,000-channel receiver for eight seconds. It receives
  RESOURCE_EXHAUSTED, with valid HTTP/2 termination.
- Actual Crystal gRPC client: first-read unblock SUCCESS; final status OK.
- POD5 round-trip: official pod5 Reader reads every output and signals match the
  raw files exactly. FAST5 signals match through h5py and the ONT fast5 reader.
  POD5-to-replay conversion and configuration validation pass.

Crystal formatting, Ameba (20 files), Black and Ruff pass; tool versions are in
`requirements-dev.txt`. The initial commit audit is recorded in `AUDIT.md`.
This document retains the validation summary; per-run logs and old measurement
files are not part of the source tree. Reproduce the functional checks with:

```sh
shards build --release
python3 -m pip install -r requirements-test.txt
sh scripts/test.sh
```

## Unmodified upstream dependencies

Revalidated on 2026-10-30 with the application-level Float extensions removed.

The current dependency pins include the upstream gRPC transport fixes:

- gRPC: `867a084acf52ae6713522171097bd2a257bcc73c`.
- proto: `675d91e11138e48aaeaa96e2325f42a8abe8a57e`.
- MinKNOW: `1b7df10fa6eb53bb1e3687c5da2b4d9b19f3e60b`.

Fresh installs with `shards install --frozen` succeeded without local patches.
`shards build --release` uses the application target in `shard.yml` and the
versions in `shard.lock`. Dependencies and binaries are created in `lib/` and `bin/` during
the build rather than included in the source tree.
The installed dependency sources match the pinned upstream files; installer
metadata, dependency symlinks and unpopulated submodules are excluded from that
comparison.

`shards build --release` builds the release executable. Ameba runs separately
as a development check through `scripts/test.sh`.
With those unmodified dependencies, `sh scripts/test.sh` passed all 24 Crystal
examples, Crystal formatting, Ameba (20 files), independent Python plaintext/TLS
and 3,000-channel communication, five edge cases, stalled-consumer termination
and POD5/FAST5 round-trip/replay validation (11 reads). The Python client used
Python 3.12.9 with `requirements-test.txt`. R10 configuration validation also passed.

MinKNOW's pinned generated well-known types have also been regenerated upstream.
The `Float32/64#to_bits` calls and the application-level Float extensions have
been removed. Neither dependency patches nor a local compatibility helper are
required. MinKNOW's 14 specs, all example type-checks and full regeneration
comparison passed before its updated commit was pushed.

## Offline equivalence

The same deterministic offline configuration (8 pores, 4 workers, 2 seconds,
R10 model plus adapter, short reads) was run with the 0.1.0 and 0.1.1 binaries.
All 72 read metadata records and signal files matched byte-for-byte after sorting
records by content.

## Load tests

Configuration: four CPU workers, 5,000 samples/sec/pore, 400-ms delivery ticks,
small repeated DNA reference (~100 kb), bundled 9-mer model, Gaussian noise,
no disk recording, independent Python client that checks byte counts and sample
continuity and sends unblock actions. Unblock latency includes transport,
coordination and Python receiver scheduling. RSS includes the whole server.
The adapter option was not enabled in these load tests.

The following longer baseline runs were collected with 0.1.0:

| Pores | Duration | Received signal | Peak RSS | Unblock p50 | p95 | p99 |
|---:|---:|---:|---:|---:|---:|---:|
| 512 | 30 s | 152.556 MB | 45.3 MiB | 4.48 ms | 6.76 ms | 8.61 ms |
| 3000 | 20 s | 597.370 MB | 42.9 MiB | 45.70 ms | 58.51 ms | 59.27 ms |
| 3000 | 120 s | 3572.312 MB | 44.0 MiB | 47.31 ms | 65.70 ms | 80.18 ms |

The 0.1.1 cleanup was checked with a further 3,000-pore, 20-second run:
597.368 MB received, 44.6 MiB peak RSS, 49 acknowledged actions, latency
p50 48.75 ms / p95 71.27 ms / p99 75.07 ms. This is a regression smoke test, not evidence of a
performance improvement or a statistically controlled comparison.

These RSS values are for a tiny reference, not a human-genome run. The full
reference is stored at one byte/base with extra transient loading copies.
No claim is made about hard real-time deadlines, multi-day stability, actual
MinKNOW hardware behavior, or Dorado accuracy.

## Dependency defects found and fixed

The pinned upstream gRPC commit `867a084acf52ae6713522171097bd2a257bcc73c`
includes the following corrections, previously carried as a local patch:

1. A gRPC message spanning multiple DATA frames must retain its provider until
   all bytes have been consumed. The original callback advanced on every frame.
2. Release the GC anchor for the completed streaming buffer rather than retaining
   every message until the entire stream closes.
3. Bound pending transport messages to eight and yield outside the lock. A
   five-second transport stall raises RESOURCE_EXHAUSTED.
4. Once response HEADERS have been sent, an error must be sent as terminal trailers
   behind pending DATA, not as another initial :status header block.
5. Use the correct linker library name `nghttp2`, with `libnghttp2` as pkg-config name.

Older generated MinKNOW wrappers called `Float32/64#to_bits`. Upstream regeneration
now emits Crystal-compatible floating-point checks that preserve negative zero.
The former application-level compatibility extension has been removed. Installed
generated protocol files are identical to the pinned upstream source.

## Remaining validation boundaries

The simplified signal model's physical fidelity, current Dorado basecalling,
full readfish workflows, real human-genome references, macOS and Windows have
not been validated here. POD5 is exported after a run through the Crystal tool;
the live Crystal process stores raw per-read files. Real-signal replay is provided
for downstream basecaller testing. API support is listed in `API.md`.
