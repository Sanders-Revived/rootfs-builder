#!/usr/bin/env python3
"""Build an Android v0 boot image with the legacy Qualcomm DT table field."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path


BOOT_MAGIC = b"ANDROID!"
BOOT_NAME_SIZE = 16
BOOT_ARGS_SIZE = 512
BOOT_EXTRA_ARGS_SIZE = 1024


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def padded(data: bytes, alignment: int) -> bytes:
    return data + bytes(align(len(data), alignment) - len(data))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--qcdt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base", type=lambda value: int(value, 0), default=0x10000000)
    parser.add_argument("--kernel-offset", type=lambda value: int(value, 0), default=0x8000)
    parser.add_argument("--ramdisk-offset", type=lambda value: int(value, 0), default=0x01000000)
    parser.add_argument("--second-offset", type=lambda value: int(value, 0), default=0x00F00000)
    parser.add_argument("--tags-offset", type=lambda value: int(value, 0), default=0x100)
    parser.add_argument("--pagesize", type=int, default=2048)
    parser.add_argument("--cmdline", default="")
    parser.add_argument("--board", default="sanders")
    args = parser.parse_args()

    if args.pagesize <= 0 or args.pagesize & (args.pagesize - 1):
        parser.error("--pagesize must be a positive power of two")

    kernel = args.kernel.read_bytes()
    qcdt = args.qcdt.read_bytes()
    cmdline = args.cmdline.encode() + b"\0"
    board = args.board.encode() + b"\0"
    if len(cmdline) > BOOT_ARGS_SIZE + BOOT_EXTRA_ARGS_SIZE - 1:
        parser.error("cmdline is too long")
    if len(board) > BOOT_NAME_SIZE:
        parser.error("board name is too long")

    cmdline_main = cmdline[: BOOT_ARGS_SIZE - 1]
    cmdline_extra = cmdline[BOOT_ARGS_SIZE - 1 :]
    cmdline_main = cmdline_main.ljust(BOOT_ARGS_SIZE, b"\0")
    cmdline_extra = cmdline_extra.ljust(BOOT_EXTRA_ARGS_SIZE, b"\0")
    board = board.ljust(BOOT_NAME_SIZE, b"\0")

    kernel_addr = args.base + args.kernel_offset
    ramdisk_addr = args.base + args.ramdisk_offset
    second_addr = args.base + args.second_offset
    tags_addr = args.base + args.tags_offset
    image_id_data = (
        kernel
        + struct.pack("<I", len(kernel))
        + struct.pack("<I", 0)
        + struct.pack("<I", 0)
        + qcdt
        + struct.pack("<I", len(qcdt))
    )
    image_id = hashlib.sha1(image_id_data).digest().ljust(32, b"\0")

    header = struct.pack(
        "<8s10I16s512s8I1024s",
        BOOT_MAGIC,
        len(kernel),
        kernel_addr,
        0,
        ramdisk_addr,
        0,
        second_addr,
        tags_addr,
        args.pagesize,
        len(qcdt),
        0,
        board,
        cmdline_main,
        *struct.unpack("<8I", image_id),
        cmdline_extra,
    )

    image = padded(header, args.pagesize)
    image += padded(kernel, args.pagesize)
    image += padded(qcdt, args.pagesize)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)


if __name__ == "__main__":
    main()
