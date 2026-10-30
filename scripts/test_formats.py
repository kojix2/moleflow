#!/usr/bin/env python3
import json
import pathlib
import subprocess
import tempfile

import numpy as np
import pod5
from integration import ROOT

with tempfile.TemporaryDirectory() as td:
    td = pathlib.Path(td)
    output = td / "output"
    c = dict(
        samples=[dict(path=str(ROOT / "examples/reference.fa"), circular=True)],
        channels=4,
        workers=2,
        duration_seconds=1.0,
        mean_read_length=100,
        output=str(output),
    )
    (td / "c.json").write_text(json.dumps(c))
    subprocess.run(
        [str(ROOT / "bin/moleflow"), "--simulate", "-c", str(td / "c.json")], check=True
    )
    subprocess.run(
        [str(ROOT / "scripts/pod5.sh"), "convert", str(output), str(td / "run.pod5")],
        check=True,
    )
    rows = {
        r["read_id"]: r
        for r in map(json.loads, (output / "reads.jsonl").read_text().splitlines())
        if r["sample_count"]
    }
    with pod5.Reader(td / "run.pod5") as f:
        assert f.num_reads == len(rows)
        for r in f.reads():
            expected = np.fromfile(output / "signal" / f"{r.read_id}.i16", dtype="<i2")
            assert np.array_equal(r.signal, expected)
            assert r.run_info.sample_rate == 5000
            assert len(r.signal) == rows[str(r.read_id)]["sample_count"]
    subprocess.run(
        [
            str(ROOT / "scripts/pod5.sh"),
            "prepare",
            str(td / "run.pod5"),
            str(td / "replay"),
            "--limit=1000",
        ],
        check=True,
    )
    replay_config = json.loads((td / "replay/replay.json").read_text())
    replay_paths = {
        pathlib.Path(item["path"]).stem: item["path"]
        for item in replay_config["samples"]
    }
    with pod5.Reader(td / "run.pod5") as f:
        for r in f.reads():
            expected = np.rint(
                (r.signal.astype(np.float64) + r.calibration.offset)
                * r.calibration.scale
                / replay_config["scale"]
                - replay_config["offset"]
            )
            actual = np.fromfile(replay_paths[str(r.read_id)], dtype="<i2")
            assert np.array_equal(actual, expected.astype("<i2"))
    subprocess.run(
        [
            str(ROOT / "bin/moleflow"),
            "--validate",
            "-c",
            str(td / "replay/replay.json"),
        ],
        check=True,
    )
    print("POD5 round-trip and replay preparation passed:", len(rows), "reads")
