# Code organization

| File under `src/` | Responsibility |
|---|---|
| `main.cr` | CLI parsing, configuration loading and user-facing errors |
| `moleflow/application.cr` | Offline execution and server startup/shutdown |
| `moleflow/config.cr` | JSON schema, defaults and configuration validation |
| `moleflow/api.cr` | MinKNOW RPC routing and session admission |
| `moleflow/protocol.cr` | Generated message imports and constructors |
| `moleflow/live_session.cr` | Clock, ordered commands, transport queues and session cleanup |
| `moleflow/stream_settings.cr` | Channel ranges and live setup validation |
| `moleflow/response_encoder.cr` | Minimum chunks, filtering, calibration and protobuf batching |
| `moleflow/source.cr` | FASTA and replay source loading |
| `moleflow/model.cr`, `noise.cr` | Dense k-mer currents, bounded adapter input and deterministic noise |
| `moleflow/molecule.cr` | Read identity and signal generation/replay |
| `moleflow/engine.cr` | Pore/read lifecycle and actions, owned by one worker |
| `moleflow/worker_pool.cr` | Worker contexts, command dispatch and result collection |
| `moleflow/output.cr`, `async_output.cr` | Raw recording and bounded asynchronous disk writes |

Only the live-session coordinator updates setup and partial response chunks.
Each signal worker owns its pores and random generators. Shared reference/model
data is read-only after startup. The disk worker is the single owner of output
files. These ownership rules matter more than the number of fibers.
The run directory is created atomically before recording files are written.

`Pool` and `AsyncOutput` are single-coordinator interfaces, not general concurrent
services. `close` is idempotent; new work after close is rejected. Terminal output
is submitted before the disk queue closes. The live RPC waits for the sender's
final result before returning success.
Disk shutdown waits at most six seconds, then reports incomplete output if the
worker is still blocked. A blocked operating-system write is not cancelled.

Application-level bounded queues do not replace transport-level backpressure.
The pinned upstream gRPC dependency includes the transport fixes; no local
patches are required. `shards install --frozen` restores the verified revisions.
`shards build --release` installs dependencies and builds the application target
declared in `shard.yml`.
The pinned MinKNOW dependency includes regenerated Google protobuf types, so the
application does not extend Crystal's Float types to support generated code.

Formatting and Python lint checks (the development tools are version-pinned):

```sh
python3 -m pip install -r requirements-dev.txt
crystal tool format --check src spec
python3 -m black --check scripts
python3 -m ruff check scripts
```

Run `sh scripts/test.sh` after building `bin/moleflow`. See `VALIDATION.md` for
the recorded scope.

Ameba is pinned in `development_dependencies` and installed through Shards.
`scripts/test.sh` checks Crystal formatting and invokes Ameba directly before
functional tests. Scope: src, spec, examples. The configuration
retains noun-style Boolean accessors and short loop names, and sets cyclomatic
complexity to 20 for RPC dispatch/state-machine methods. All other default
rules remain enabled; no generated baseline or per-file exclusions are used.
