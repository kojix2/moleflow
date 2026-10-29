#!/usr/bin/env python3
import json
import pathlib
import subprocess
import tempfile

import h5py
import numpy as np
import pod5
from convert_output import convert
from integration import ROOT
from prepare_replay import prepare

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
    convert(output, td / "run.pod5")
    convert(output, td / "run.fast5")
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
    with h5py.File(td / "run.fast5") as f:
        assert len(f) == len(rows)
        for rid, row in rows.items():
            assert np.array_equal(
                f["read_" + rid + "/Raw/Signal"][:],
                np.fromfile(output / "signal" / f"{rid}.i16", dtype="<i2"),
            )
    try:
        from ont_fast5_api.fast5_interface import get_fast5_file
    except ImportError:
        pass
    else:
        with get_fast5_file(str(td / "run.fast5"), mode="r") as f:
            assert len(f.get_read_ids()) == len(rows)
            for read in f.get_reads():
                assert len(read.get_raw_data()) == rows[read.read_id]["sample_count"]
    prepare(td / "run.pod5", td / "replay", 1000)
    subprocess.run(
        [
            str(ROOT / "bin/moleflow"),
            "--validate",
            "-c",
            str(td / "replay/replay.json"),
        ],
        check=True,
    )
    print("POD5/FAST5 round-trip and replay preparation passed:", len(rows), "reads")
