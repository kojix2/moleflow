#!/usr/bin/env python3
"""Convert an Moleflow raw-output directory to official POD5 or multi-read FAST5.
One completed read is resident at a time. Requires numpy and pod5 or h5py.
"""

import argparse
import datetime
import json
import pathlib
import uuid

import numpy as np


def convert(directory, destination):
    directory = pathlib.Path(directory)
    destination = pathlib.Path(destination)
    if destination.exists():
        raise ValueError("destination already exists")
    config = json.loads((directory / "config.json").read_text())
    start = datetime.datetime(2026, 1, 1, tzinfo=datetime.UTC)
    scale, offset = config["scale"], config["offset"]

    def records():
        with (directory / "reads.jsonl").open() as rows:
            for line in rows:
                row = json.loads(line)
                if row["sample_count"] == 0:
                    continue
                signal = np.fromfile(
                    directory / "signal" / f"{row['read_id']}.i16", dtype="<i2"
                )
                if len(signal) != row["sample_count"]:
                    raise ValueError("signal length mismatch")
                yield row, signal

    if destination.suffix == ".pod5":
        import pod5 as p

        run = p.RunInfo(
            acquisition_id=f"moleflow-{config['seed']}",
            acquisition_start_time=start,
            adc_max=32767,
            adc_min=-32768,
            context_tags={
                "experiment_type": "genomic_dna",
                "sample_frequency": str(config["sample_rate"]),
            },
            experiment_name="moleflow-simulation",
            flow_cell_id="MOLEFLOW",
            flow_cell_product_code="FLO-MIN114",
            protocol_name="moleflow",
            protocol_run_id=f"moleflow-{config['seed']}",
            protocol_start_time=start,
            sample_id="simulated",
            sample_rate=config["sample_rate"],
            sequencing_kit="SQK-LSK114",
            sequencer_position="MOLEFLOW",
            sequencer_position_type="simulation",
            software="moleflow",
            system_name="simulation",
            system_type="simulation",
            tracking_id={"simulation": "true"},
        )
        with p.Writer(destination) as writer:
            for row, signal in records():
                reason = (
                    p.EndReasonEnum.UNBLOCK_MUX_CHANGE
                    if row["end_reason"] == "unblock_mux_change"
                    else (
                        p.EndReasonEnum.SIGNAL_POSITIVE
                        if row["end_reason"] == "signal_positive"
                        else p.EndReasonEnum.API_REQUEST
                    )
                )
                writer.add_read(
                    p.Read(
                        read_id=uuid.UUID(row["read_id"]),
                        pore=p.Pore(
                            channel=row["channel"], well=1, pore_type="not_set"
                        ),
                        calibration=p.Calibration(offset=offset, scale=scale),
                        read_number=row["number"],
                        start_sample=row["start_sample"],
                        median_before=100.0,
                        end_reason=p.EndReason(
                            reason=reason, forced=row["end_reason"] != "signal_positive"
                        ),
                        run_info=run,
                        signal=signal,
                    )
                )
    elif destination.suffix == ".fast5":
        import h5py

        with h5py.File(destination, "w") as f:
            f.attrs["file_type"] = "multi-read"
            f.attrs["file_version"] = "2.0"
            for row, signal in records():
                g = f.create_group("read_" + row["read_id"])
                raw = g.create_group("Raw")
                raw.create_dataset("Signal", data=signal, compression="gzip")
                raw.attrs.update(
                    read_id=np.bytes_(row["read_id"]),
                    read_number=row["number"],
                    start_time=row["start_sample"],
                    duration=row["sample_count"],
                    start_mux=1,
                    median_before=100.0,
                )
                channel = g.create_group("channel_id")
                channel.attrs.update(
                    channel_number=np.bytes_(str(row["channel"])),
                    digitisation=2048.0,
                    range=scale * 2048,
                    offset=offset,
                    sampling_rate=float(config["sample_rate"]),
                )
                context = g.create_group("context_tags")
                context.attrs.update(
                    experiment_type=np.bytes_("genomic_dna"),
                    sample_frequency=np.bytes_(str(config["sample_rate"])),
                )
                track = g.create_group("tracking_id")
                track.attrs.update(
                    run_id=np.bytes_(f"moleflow-{config['seed']}"),
                    flow_cell_id=np.bytes_("MOLEFLOW"),
                    exp_start_time=np.bytes_(start.isoformat()),
                    device_id=np.bytes_("MOLEFLOW"),
                    software=np.bytes_("moleflow"),
                )
    else:
        raise ValueError("destination must end in .pod5 or .fast5")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("destination")
    args = parser.parse_args()
    convert(args.directory, args.destination)
