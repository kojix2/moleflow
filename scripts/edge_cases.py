#!/usr/bin/env python3
"""Interoperability regression tests for setup, filtering, actions and shutdown."""

import contextlib
import json
import pathlib
import queue
import subprocess
import tempfile
import time

import grpc
from integration import ROOT, port
from minknow_api import data_pb2 as d
from minknow_api import data_pb2_grpc as dg


@contextlib.contextmanager
def server(channels=4, seconds=1.0, chunk=50, output=False):
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        pp, mp = port(), port()
        c = dict(
            samples=[dict(path=str(ROOT / "examples/reference.fa"), circular=True)],
            channels=channels,
            workers=2,
            duration_seconds=seconds,
            chunk_ms=chunk,
            position_port=pp,
            manager_port=mp,
        )
        if output:
            c["output"] = str(td / "out")
        (td / "c.json").write_text(json.dumps(c))
        log = open(td / "log", "w+")
        p = subprocess.Popen(
            [str(ROOT / "bin/moleflow"), "-c", str(td / "c.json")],
            stdout=log,
            stderr=log,
        )
        conn = grpc.insecure_channel(f"localhost:{pp}")
        try:
            grpc.channel_ready_future(conn).result(timeout=10)
            yield dg.DataServiceStub(conn), p, td
        finally:
            conn.close()
            p.terminate()
            try:
                p.wait(timeout=12)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
                raise AssertionError("shutdown hung")
            log.close()


def stream(stub, setup):
    q = queue.Queue()
    q.put(d.GetLiveReadsRequest(setup=setup))

    def gen():
        while True:
            a = q.get()
            if a is None:
                return
            yield a

    return stub.get_live_reads(gen(), timeout=10), q


def check():
    # Per-read minimum, channel selection and contiguous coordinates.
    with server() as (stub, p, td):
        call, q = stream(
            stub,
            d.GetLiveReadsRequest.StreamSetup(
                first_channel=2,
                last_channel=3,
                raw_data_type=3,
                sample_minimum_chunk_size=700,
            ),
        )
        seen = {}
        count = 0
        for response in call:
            for ch, r in response.channels.items():
                assert ch in (2, 3) and r.chunk_length >= 700
                if r.id in seen:
                    assert seen[r.id] == r.chunk_start_sample
                seen[r.id] = r.chunk_start_sample + r.chunk_length
                count += 1
        q.put(None)
        assert count > 0
    # Stop-further-data must not unblock; continue saving the molecule to disk.
    with server(output=True) as (stub, p, td):
        call, q = stream(
            stub,
            d.GetLiveReadsRequest.StreamSetup(
                first_channel=1, last_channel=4, raw_data_type=3
            ),
        )
        target = None
        acked = False
        further = 0
        for response in call:
            for a in response.action_responses:
                if a.action_id == "stop":
                    assert a.response == 0
                    acked = True
            for ch, r in response.channels.items():
                if target is None:
                    target = r.id
                    q.put(
                        d.GetLiveReadsRequest(
                            actions=d.GetLiveReadsRequest.Actions(
                                actions=[
                                    d.GetLiveReadsRequest.Action(
                                        channel=ch,
                                        id=r.id,
                                        action_id="stop",
                                        stop_further_data=d.GetLiveReadsRequest.StopFurtherData(),
                                    )
                                ]
                            )
                        )
                    )
                elif r.id == target and acked:
                    further += 1
        q.put(None)
        assert acked and further == 0
        rows = [
            json.loads(x) for x in (td / "out/reads.jsonl").read_text().splitlines()
        ]
        row = next(r for r in rows if r["read_id"] == target)
        assert row["sample_count"] == 5000 and row["end_reason"] == "simulation_end"
    # Live setup update, KEEP_LAST, then NONE.
    with server() as (stub, p, td):
        call, q = stream(
            stub,
            d.GetLiveReadsRequest.StreamSetup(
                first_channel=1, last_channel=1, raw_data_type=3
            ),
        )
        changed = False
        saw_none = False
        for response in call:
            if response.channels and not changed:
                changed = True
                q.put(
                    d.GetLiveReadsRequest(
                        setup=d.GetLiveReadsRequest.StreamSetup(
                            first_channel=4, last_channel=4, raw_data_type=1
                        )
                    )
                )
            for ch, r in response.channels.items():
                if ch == 4:
                    assert r.raw_data == b""
                    saw_none = True
        q.put(None)
        assert saw_none
    # Bad channel ranges return a gRPC error rather than crashing the server.
    with server() as (stub, p, td):
        call, q = stream(
            stub,
            d.GetLiveReadsRequest.StreamSetup(
                first_channel=0, last_channel=99, raw_data_type=3
            ),
        )
        try:
            list(call)
            raise AssertionError("accepted invalid setup")
        except grpc.RpcError as ex:
            assert ex.code() == grpc.StatusCode.INVALID_ARGUMENT, ex
        q.put(None)
        assert p.poll() is None
    # Cancellation and TERM both flush terminal records and release workers.
    with server(seconds=60, output=True) as (stub, p, td):
        call, q = stream(
            stub,
            d.GetLiveReadsRequest.StreamSetup(
                first_channel=1, last_channel=4, raw_data_type=3
            ),
        )
        response = next(call)
        assert response.channels
        call.cancel()
        q.put(None)
        time.sleep(0.3)
        p.terminate()
        p.wait(timeout=10)
        assert p.returncode == 0
        assert (td / "out/reads.jsonl").stat().st_size > 0
    print("5 Python edge-case scenarios passed")


if __name__ == "__main__":
    check()
