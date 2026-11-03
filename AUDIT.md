# Initial commit audit

Date: 2026-10-30.

Reviewed application sources, conversion scripts, tests, configuration examples,
documentation, dependency pins, bundled asset notices and files intended for the
first commit. Dependency implementation review and vulnerability database scans
are outside this audit's scope.

## Findings and corrections

| Finding | Correction |
|---|---|
| An empty output path passed validation and could write `config.json`, `reads.jsonl` and `signal/` into the working directory. | Reject empty or whitespace-only paths. Create the run directory atomically before writing recording files, preserving existing output even when another process creates the directory concurrently. |
| Multiplying a large finite sample weight by contig length could overflow before division, corrupting sample selection. | Compute the contig fraction before multiplying by the sample weight. |
| A positive finite duration could overflow when converted into an Int64 sample time. | Validate the sample-time range and avoid overflowing the last offline time step. |
| Asynchronous output shutdown could wait forever if the disk worker stalled while writing or closing files. | Bound the shutdown wait to six seconds and report that output may be incomplete. This does not cancel a blocked operating-system write. |
| The README linked to a missing Japanese translation. | Remove the broken link. |
| Local environment and tool cache files were not ignored. | Ignore `.env` variants, `.venv/`, Ruff and pytest caches; retain `.env.example` as a possible template. |

Four regression scenarios failed against the original source: empty output,
large weights, overflowing duration and stalled disk close. They now pass.
A fifth test confirms that recording creation still supports missing parent
directories and preserves existing files. These tests are in `spec/audit_spec.cr`.

## Repository checks

- Shards dependency declarations and the lockfile agree (`shards check`).
- Application and development Shards dependencies are pinned to commits.
- The bundled signal model and adapter have provenance in `NOTICE`; dependency
  sources and build outputs remain excluded from the commit.
- A scan of commit candidates for private-key blocks, common API-token formats
  and credential assignments found no matches. This is a pattern scan, not a
  guarantee that every possible secret format is detectable.
- Relative Markdown file links resolve after the README correction.

Functional validation and reproduction commands are recorded in
[`VALIDATION.md`](VALIDATION.md). The existing limits on signal-model fidelity,
external workflow compatibility and platform coverage still apply.
