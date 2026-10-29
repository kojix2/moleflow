#!/usr/bin/env python3
"""Prepare real POD5 reads for bounded-memory replay, retaining sampling rate.
Calibration is converted to a common ADC scale; clipping is rejected.
"""

import argparse
import json
import pathlib

import numpy as np
import pod5


def prepare(source, destination, limit):
    dst = pathlib.Path(destination)
    dst.mkdir(parents=True, exist_ok=False)
    config = dict(
        samples=[],
        sample_rate=0,
        scale=0.1462070643901825,
        offset=-243.0,
        channels=512,
        workers=4,
        duration_seconds=60,
    )
    with pod5.Reader(source) as reader:
        for i, r in enumerate(reader.reads()):
            if i >= limit:
                break
            rate = r.run_info.sample_rate
            if config["sample_rate"] and config["sample_rate"] != rate:
                raise ValueError("mixed sample rates are not supported")
            config["sample_rate"] = rate
            signal = np.rint(
                (
                    (r.signal.astype(np.float64) + r.calibration.offset)
                    * r.calibration.scale
                )
                / config["scale"]
                - config["offset"]
            )
            if np.any(signal < -32768) or np.any(signal > 32767):
                raise ValueError("calibration conversion would clip")
            path = (dst / f"{r.read_id}.i16").resolve()
            signal.astype("<i2").tofile(path)
            config["samples"].append(dict(path=str(path), replay=True))
    if not config["samples"]:
        raise ValueError("no reads selected")
    (dst / "replay.json").write_text(json.dumps(config, indent=2) + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("pod5")
    p.add_argument("destination")
    p.add_argument("--limit", type=int, default=1000)
    a = p.parse_args()
    if a.limit < 1:
        p.error("--limit must be positive")
    prepare(a.pod5, a.destination, a.limit)
