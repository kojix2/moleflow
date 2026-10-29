#!/usr/bin/env python3
"""Longer real-time test: throughput, RSS, action latency, independent Python client."""

import json
import pathlib
import queue
import statistics
import subprocess
import sys
import tempfile
import threading
import time

import grpc
from integration import ROOT, port
from minknow_api import data_pb2 as d
from minknow_api import data_pb2_grpc as dg


def stress(channels, seconds):
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        pp, mp = port(), port()
        c = dict(
            samples=[dict(path=str(ROOT / "examples/reference.fa"), circular=True)],
            model=str(ROOT / "models/r10_dna.tsv"),
            channels=channels,
            workers=4,
            duration_seconds=seconds,
            chunk_ms=400,
            position_port=pp,
            manager_port=mp,
        )
        (td / "c.json").write_text(json.dumps(c))
        log = open(td / "log", "w+")
        p = subprocess.Popen(
            [str(ROOT / "bin/moleflow"), "-c", str(td / "c.json")],
            stdout=log,
            stderr=log,
        )
        conn = grpc.insecure_channel(f"localhost:{pp}")
        q = queue.Queue()
        rss = []
        latencies = []
        sent = {}
        last = {}
        samples = 0
        chunks = 0

        def monitor():
            while p.poll() is None:
                try:
                    process_status = pathlib.Path(f"/proc/{p.pid}/status")
                    if not process_status.exists():
                        for candidate in pathlib.Path("/proc").glob("[0-9]*/status"):
                            text = candidate.read_text()
                            if "Name:\tmoleflow" in text and any(
                                line.startswith("NSpid:")
                                and int(line.split()[-1]) == p.pid
                                for line in text.splitlines()
                            ):
                                process_status = candidate
                                break
                    for line in process_status.read_text().splitlines():
                        if line.startswith("VmRSS:"):
                            rss.append(int(line.split()[1]) / 1024)
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    pass
                time.sleep(0.1)

        threading.Thread(target=monitor, daemon=True).start()
        try:
            grpc.channel_ready_future(conn).result(timeout=20)
            q.put(
                d.GetLiveReadsRequest(
                    setup=d.GetLiveReadsRequest.StreamSetup(
                        first_channel=1, last_channel=channels, raw_data_type=3
                    )
                )
            )

            def requests():
                while True:
                    msg = q.get()
                    if msg is None:
                        return
                    yield msg

            t0 = time.monotonic()
            next_action = 0
            for response in dg.DataServiceStub(conn).get_live_reads(
                requests(), timeout=seconds + 30
            ):
                for ack in response.action_responses:
                    if ack.action_id in sent:
                        latencies.append(
                            (time.monotonic() - sent.pop(ack.action_id)) * 1000
                        )
                        assert ack.response in (0, 1)
                actions = []
                for ch, r in response.channels.items():
                    assert len(r.raw_data) == 2 * r.chunk_length
                    if r.id in last:
                        assert r.chunk_start_sample == last[r.id]
                    last[r.id] = r.chunk_start_sample + r.chunk_length
                    samples += r.chunk_length
                    chunks += 1
                    if ch % 100 == 1 and time.monotonic() >= next_action:
                        aid = str(chunks)
                        sent[aid] = time.monotonic()
                        actions.append(
                            d.GetLiveReadsRequest.Action(
                                action_id=aid,
                                channel=ch,
                                id=r.id,
                                unblock=d.GetLiveReadsRequest.UnblockAction(
                                    duration=0.1
                                ),
                            )
                        )
                if actions:
                    q.put(
                        d.GetLiveReadsRequest(
                            actions=d.GetLiveReadsRequest.Actions(actions=actions)
                        )
                    )
                    next_action = time.monotonic() + 0.05
            q.put(None)
            latency = sorted(latencies)
            result = dict(
                channels=channels,
                requested_seconds=seconds,
                elapsed_seconds=round(time.monotonic() - t0, 3),
                samples=samples,
                chunks=chunks,
                received_MB=round(samples * 2 / 1e6, 3),
                rss_peak_MiB=round(max(rss), 1),
                rss_second_half_min_MiB=round(min(rss[len(rss) // 2 :]), 1),
                actions=len(latencies),
                ack_p50_ms=round(statistics.median(latency), 2),
                ack_p95_ms=round(latency[int(0.95 * (len(latency) - 1))], 2),
                ack_p99_ms=round(latency[int(0.99 * (len(latency) - 1))], 2),
            )
            print(json.dumps(result))
            return result
        finally:
            conn.close()
            p.terminate()
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
            log.seek(0)
            if p.returncode:
                print(log.read(), file=sys.stderr)


if __name__ == "__main__":
    stress(
        int(sys.argv[1]) if len(sys.argv) > 1 else 3000,
        float(sys.argv[2]) if len(sys.argv) > 2 else 20,
    )
