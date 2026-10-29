#!/usr/bin/env python3
"""Independent Python gRPC interoperability tests. pip install minknow-api."""

import json
import pathlib
import queue
import socket
import subprocess
import sys
import tempfile
import time

import grpc
from minknow_api import (
    data_pb2 as d,
)
from minknow_api import (
    data_pb2_grpc as dg,
)
from minknow_api import (
    device_pb2 as dv,
)
from minknow_api import (
    device_pb2_grpc as dvg,
)
from minknow_api import (
    manager_pb2 as m,
)
from minknow_api import (
    manager_pb2_grpc as mg,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run(tls=False, channels=32, seconds=2.0, calibrated=False, slow=False):
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        mp, pp = port(), port()
        config = dict(
            samples=[dict(path=str(ROOT / "examples/reference.fa"), circular=True)],
            channels=channels,
            workers=4,
            duration_seconds=seconds,
            chunk_ms=100,
            manager_port=mp,
            position_port=pp,
            output=str(td / "out"),
            stream_queue=256,
        )
        if tls:
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    str(td / "key.pem"),
                    "-out",
                    str(td / "cert.pem"),
                    "-days",
                    "1",
                    "-subj",
                    "/CN=localhost",
                    "-addext",
                    "subjectAltName=DNS:localhost,IP:127.0.0.1",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            config.update(tls_cert=str(td / "cert.pem"), tls_key=str(td / "key.pem"))
        (td / "config.json").write_text(json.dumps(config))
        log = open(td / "server.log", "w+")
        process = subprocess.Popen(
            [str(ROOT / "bin/moleflow"), "-c", str(td / "config.json")],
            cwd=ROOT,
            stdout=log,
            stderr=log,
        )

        def connect(p):
            target = f"localhost:{p}"
            if tls:
                return grpc.secure_channel(
                    target, grpc.ssl_channel_credentials((td / "cert.pem").read_bytes())
                )
            return grpc.insecure_channel(target)

        conn = connect(pp)
        manager = connect(mp)
        try:
            grpc.channel_ready_future(conn).result(timeout=10)
            positions = list(
                mg.ManagerServiceStub(manager).flow_cell_positions(
                    m.FlowCellPositionsRequest(), timeout=5
                )
            )
            assert positions[0].positions[0].rpc_ports.secure == pp
            info = dvg.DeviceServiceStub(conn).get_calibration(
                dv.GetCalibrationRequest(first_channel=1, last_channel=channels),
                timeout=5,
            )
            assert len(info.offsets) == channels
            q = queue.Queue()
            q.put(
                d.GetLiveReadsRequest(
                    setup=d.GetLiveReadsRequest.StreamSetup(
                        first_channel=1,
                        last_channel=channels,
                        raw_data_type=(
                            d.GetLiveReadsRequest.CALIBRATED
                            if calibrated
                            else d.GetLiveReadsRequest.UNCALIBRATED
                        ),
                    )
                )
            )

            def requests():
                while True:
                    item = q.get()
                    if item is None:
                        return
                    yield item

            call = dg.DataServiceStub(conn).get_live_reads(
                requests(), timeout=seconds + 20
            )
            chunks = 0
            size = 0
            seen = {}
            sent = False
            acknowledgments = {}
            unblocked = None
            t0 = time.monotonic()
            action_at = 0
            latency = None
            for resp in call:
                for ack in resp.action_responses:
                    acknowledgments[ack.action_id] = ack.response
                    if ack.action_id == "unblock":
                        latency = time.monotonic() - action_at
                for ch, read in resp.channels.items():
                    chunks += 1
                    size += len(read.raw_data)
                    assert len(read.raw_data) == read.chunk_length * (
                        4 if calibrated else 2
                    )
                    assert read.chunk_start_sample >= read.start_sample
                    if read.id in seen:
                        assert read.chunk_start_sample == seen[read.id]
                    seen[read.id] = read.chunk_start_sample + read.chunk_length
                    if not sent:
                        sent = True
                        action_at = time.monotonic()
                        unblocked = read.id
                        q.put(
                            d.GetLiveReadsRequest(
                                actions=d.GetLiveReadsRequest.Actions(
                                    actions=[
                                        d.GetLiveReadsRequest.Action(
                                            action_id="unblock",
                                            channel=ch,
                                            id=read.id,
                                            unblock=d.GetLiveReadsRequest.UnblockAction(
                                                duration=0.1
                                            ),
                                        ),
                                        d.GetLiveReadsRequest.Action(
                                            action_id="stale",
                                            channel=ch,
                                            id="bad-id",
                                            unblock=d.GetLiveReadsRequest.UnblockAction(
                                                duration=0.1
                                            ),
                                        ),
                                    ]
                                )
                            )
                        )
                if slow:
                    time.sleep(0.02)
            q.put(None)
            assert (
                chunks > 0
                and acknowledgments.get("unblock") == 0
                and acknowledgments.get("stale") == 1
            ), acknowledgments
            rows = [
                json.loads(x) for x in (td / "out/reads.jsonl").read_text().splitlines()
            ]
            for row in rows:
                path = td / "out/signal" / f'{row["read_id"]}.i16'
                assert (path.stat().st_size if path.exists() else 0) == row[
                    "sample_count"
                ] * 2, row
            assert any(
                r["read_id"] == unblocked and r["end_reason"] == "unblock_mux_change"
                for r in rows
            )
            print(
                json.dumps(
                    dict(
                        tls=tls,
                        channels=channels,
                        seconds=seconds,
                        calibrated=calibrated,
                        chunks=chunks,
                        bytes=size,
                        unblock_ack_ms=round(latency * 1000, 2),
                        elapsed=round(time.monotonic() - t0, 2),
                    )
                )
            )
        finally:
            conn.close()
            manager.close()
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.seek(0)
            if process.returncode not in (0, -15):
                print(log.read(), file=sys.stderr)
            log.close()


if __name__ == "__main__":
    run()
    run(tls=True, calibrated=True)
    run(channels=int(sys.argv[1]) if len(sys.argv) > 1 else 512, seconds=3)
