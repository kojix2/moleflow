#!/usr/bin/env python3
import time

import grpc
from edge_cases import server, stream
from minknow_api import data_pb2 as d

with server(channels=3000, seconds=30, chunk=100) as (stub, p, td):
    call, q = stream(
        stub,
        d.GetLiveReadsRequest.StreamSetup(
            first_channel=1, last_channel=3000, raw_data_type=3
        ),
    )
    assert next(call).channels
    time.sleep(8)
    try:
        for _ in call:
            pass
        raise AssertionError("slow client should exceed bounded queues")
    except grpc.RpcError as ex:
        assert ex.code() == grpc.StatusCode.RESOURCE_EXHAUSTED, (
            ex.code(),
            ex.details(),
        )
        print("slow consumer terminated explicitly:", ex.code().name)
    q.put(None)
