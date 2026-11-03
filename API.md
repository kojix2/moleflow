# API compatibility

Tested independently with Python minknow-api 6.10.3 and grpcio. The v0.1 server
reports a MinKNOW 6.1.4 compatibility version, inherited from the Icarust target;
this is simulated metadata, not an installed MinKNOW version.

| Service | RPCs |
|---|---|
| manager | flow_cell_positions (server stream) |
| instance | get_version_info |
| device | get_flow_cell_info, get_sample_rate, get_calibration |
| acquisition | current_status, get_current_acquisition_run, get_acquisition_info |
| protocol | get_current_protocol_run, get_run_info |
| analysis_configuration | get_read_classifications, get_analysis_configuration |
| data | get_data_types, get_live_reads (bidirectional stream) |
| log | send_user_message |

Other methods return UNIMPLEMENTED. Metadata is a small simulation fixture;
there is no real hardware, basecaller, run-control stack or acquisition database.
One position and one live-read session are supported per process.

`get_live_reads`:

- Initial setup is mandatory. A later setup can change channel range, raw type,
  classification filter, minimum chunk size and maximum unblock read age.
- Channel numbers are inclusive, one-based. Invalid ranges return INVALID_ARGUMENT.
- KEEP_LAST, NONE, CALIBRATED (Float32 LE), UNCALIBRATED (Int16 LE) are supported.
- Only the `strand` classification is generated. The first-chunk filter is applied
  consistently throughout a read.
- `sample_minimum_chunk_size` buffers at most one partial chunk per pore. A
  terminal remainder smaller than the requested minimum is omitted from client
  delivery, but retained in raw output. Setup changes discard partial client buffers.
- `start_sample` and `chunk_start_sample` are absolute acquisition sample positions.
- Actions require a read UUID. Legacy read-number-based action requests are not
  supported by the pinned generated protocol.
- Unblock and stop-further-data acknowledge every valid action, including stale
  read IDs. Unsupported or malformed requests return an error.
- The raw-data, request, output and disk queues have finite capacities. A client
  that cannot sustain real-time throughput receives an explicit error. A run does
  not silently slow down to virtual time in live mode.
- Client request-stream completion, cancellation or disconnect ends this simulation
  session. Restart the process for a fresh session. Simulations do not continue
  across client reconnects.

No authentication is emulated. TLS uses the provided server certificate; configure
the client's trusted CA (e.g. MINKNOW_TRUSTED_CA) appropriately. Default binding is
loopback. Do not assume compatibility with every readfish/Read Until release based
on the metadata version; the included independent tests define the tested subset.

## In-process observations and recordings

Pass an optional `Moleflow::Observer` to `Application` to receive physical
`ReadProgress` snapshots in `on_progress`. These include stopped-data reads:
Accept stops live-read delivery, while their sample cursor continues advancing.
A nonempty `end_reason` identifies a terminal snapshot. Rejected/interrupted
reads can end before `total_samples`. Snapshots are values captured by signal
workers and delivered on the coordinator; consumers own channel filtering and
throttling and must return promptly. They are observations, not policy inputs.
Direct `Engine`/`Pool` users can request these snapshots with `observe: true`
and read `Tick#progress`; observation is disabled by default.

`on_recording_closed(directory)` runs after output has successfully drained and
closed. `Moleflow::Recording` exposes the same completion through `complete?`.
Its `read_available` method yields flushed `RecordedRead` metadata once, waits
for complete JSONL lines, and maintains its own cursor. `drained?` combines the
completion marker and cursor position. `read_signal(read, max_bytes: limit)`
checks identifiers, allocation bounds and signal length before reading ADC.
Older recordings without a completion marker remain readable; their completion
cannot be inferred. POD5 conversion uses the same metadata type and existing
pod5.cr writer.
