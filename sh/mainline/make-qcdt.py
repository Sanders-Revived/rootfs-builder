#!/usr/bin/env python3
"""Create the legacy Qualcomm QCDT v2 table consumed by lk2nd."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


QCDT_MAGIC = 0x54444351  # bytes: QCDT
QCDT_VERSION = 2
HEADER_SIZE = 12
ENTRY_SIZE = 24

# These are the QCDT v2 board tuples accepted by the current Sanders lk2nd.
# The first tuple is the one printed by a diagnostic lk2nd build on the target
# device (platform 0x125, hardware 0x8, subtype 0, SOC revision 0).  The
# remaining tuples retain compatibility with older Sanders lk2nd variants.
SANDERS_BOARD_PAIRS = (
    (0x8, 0x0),
    (0x4B, 0x8100),
    (0x4B, 0x8200),
    (0x4B, 0x8300),
    (0x4B, 0x83B0),
    (0x4B, 0x8400),
    (0x4C, 0x8400),
)


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("dtb", type=Path)
    parser.add_argument("--page-size", type=int, default=2048)
    parser.add_argument("--msm-id", type=lambda value: int(value, 0), default=293)
    # The QCDT platform ID is the MSM8953 value 0x125.  Sanders' lk2nd
    # device tree supplies the board-id/subtype pairs used below.
    parser.add_argument("--board-id", type=lambda value: int(value, 0), default=None)
    parser.add_argument("--board-subtype", type=lambda value: int(value, 0), default=None)
    parser.add_argument("--soc-rev", type=lambda value: int(value, 0), default=0)
    args = parser.parse_args()

    if args.page_size <= 0 or args.page_size & (args.page_size - 1):
        parser.error("--page-size must be a positive power of two")

    dtb = args.dtb.read_bytes()
    if len(dtb) < 8 or dtb[:4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit(f"not a flattened device tree: {args.dtb}")

    if (args.board_id is None) != (args.board_subtype is None):
        raise SystemExit("--board-id and --board-subtype must be used together")

    board_pairs = SANDERS_BOARD_PAIRS
    if args.board_id is not None:
        board_pairs = ((args.board_id, args.board_subtype),)

    # QCDT v2 has six uint32 fields per record.  The payload starts on the
    # first page after the header, records and their terminating zero word.
    # Each record must point to its own DTB payload.  Some lk2nd versions
    # count the payloads rather than the records; reusing one offset for all
    # records makes them see only one DTB and fail device-tree selection.
    table_offset = align(
        HEADER_SIZE + ENTRY_SIZE * len(board_pairs) + 4,
        args.page_size,
    )
    dtb_stride = align(len(dtb), args.page_size)

    image = bytearray(table_offset + dtb_stride * len(board_pairs))
    image[0:HEADER_SIZE] = struct.pack(
        "<3I", QCDT_MAGIC, QCDT_VERSION, len(board_pairs)
    )
    for index, (board_id, board_subtype) in enumerate(board_pairs):
        dtb_offset = table_offset + index * dtb_stride
        entry = struct.pack(
            "<6I",
            args.msm_id,
            board_id,
            board_subtype,
            args.soc_rev,
            dtb_offset,
            len(dtb),
        )
        start = HEADER_SIZE + index * ENTRY_SIZE
        image[start : start + ENTRY_SIZE] = entry
        image[dtb_offset : dtb_offset + len(dtb)] = dtb
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)


if __name__ == "__main__":
    main()
