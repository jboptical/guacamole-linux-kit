#!/usr/bin/env python3
"""Minimal Android boot image header v2 packer (AOSP-compatible layout).
Usage: mkbootimg_v2.py KERNEL DTB OUT [CMDLINE]"""
import hashlib, struct, sys

PAGE = 4096
BASE = 0x00000000
KERNEL_OFF, RAMDISK_OFF, SECOND_OFF, TAGS_OFF, DTB_OFF = 0x8000, 0x01000000, 0x00f00000, 0x100, 0x01f00000
OS_VERSION = (12 << 14 | 0 << 7 | 0) << 11 | ((2022 - 2000) << 4 | 12)

def pad(b):
    return b + b"\0" * ((-len(b)) % PAGE)

kernel = open(sys.argv[1], "rb").read()
dtb = open(sys.argv[2], "rb").read()
cmdline = (sys.argv[4] if len(sys.argv) > 4 else "").encode()
ramdisk = second = recovery_dtbo = b""
assert len(cmdline) < 512

sha = hashlib.sha1()
for blob in (kernel, ramdisk, second, recovery_dtbo, dtb):
    sha.update(blob)
    sha.update(struct.pack("<I", len(blob)))
img_id = sha.digest() + b"\0" * 12

hdr = struct.pack("<8s10I16s512s32s1024sIQIIQ",
    b"ANDROID!",
    len(kernel), BASE + KERNEL_OFF,
    len(ramdisk), BASE + RAMDISK_OFF,
    len(second), BASE + SECOND_OFF,
    BASE + TAGS_OFF, PAGE, 2, OS_VERSION,
    b"", cmdline, img_id, b"",
    0, 0, 1660,
    len(dtb), BASE + DTB_OFF)
assert len(hdr) == 1660, len(hdr)
with open(sys.argv[3], "wb") as f:
    f.write(pad(hdr) + pad(kernel) + pad(dtb))
print("wrote", sys.argv[3])
