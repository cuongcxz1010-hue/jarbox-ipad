#!/usr/bin/env python3
"""Build selftest.jar: the conformance MIDlet, a hand-assembled class in the
oldest format (version 45.3, jsr/ret) and a small PNG with transparency.

  build.py <minijvm_rt.jar> <j2me_api.jar> <output.jar>
"""
import io
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def old_code_class():
    """OldCode.compute() = 42, written with jsr/ret as javac 1.1-1.3 did:

        0: jsr 10          ; subroutine pushes 40 to local 1
        3: iload_1
        4: iconst_2
        5: iadd
        6: goto 14
        9: nop
       10: astore_2        ; store return address
       11: bipush 40
       13: istore_1
           ret 2           ; (padded so offsets stay simple)
    """
    pool = []

    def add(entry):
        pool.append(entry)
        return len(pool)

    utf = lambda s: add(b"\x01" + struct.pack(">H", len(s)) + s.encode())
    code_name = utf("Code")
    this_name = utf("OldCode")
    this_class = add(b"\x07" + struct.pack(">H", this_name))
    object_name = utf("java/lang/Object")
    object_class = add(b"\x07" + struct.pack(">H", object_name))
    method_name = utf("compute")
    method_desc = utf("()I")

    code = bytes([
        0xA8, 0x00, 0x08,   # 0: jsr +8 -> 8
        0x1B,               # 3: iload_1
        0x05,               # 4: iconst_2
        0x60,               # 5: iadd
        0xAC,               # 6: ireturn
        0x00,               # 7: nop
        0x4D,               # 8: astore_2
        0x10, 40,           # 9: bipush 40
        0x3C,               # 11: istore_1
        0xA9, 0x02,         # 12: ret 2
    ])

    attribute = struct.pack(">HHI", 3, 3, len(code)) + code + struct.pack(">HH", 0, 0)
    method = struct.pack(">HHHH", 0x0009, method_name, method_desc, 1)
    method += struct.pack(">HI", code_name, len(attribute)) + attribute

    out = io.BytesIO()
    out.write(struct.pack(">IHH", 0xCAFEBABE, 3, 45))
    out.write(struct.pack(">H", len(pool) + 1))
    for entry in pool:
        out.write(entry)
    out.write(struct.pack(">HHHH", 0x0021, this_class, object_class, 0))
    out.write(struct.pack(">HH", 0, 1))
    out.write(method)
    out.write(struct.pack(">H", 0))
    return out.getvalue()


def test_png():
    """4x6 RGBA: first pixel red, last row's pixel (3,5) transparent, the rest blue."""
    w, h = 4, 6
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            if x == 0 and y == 0:
                raw += bytes([255, 0, 0, 255])
            elif x == 3 and y == 5:
                raw += bytes([0, 0, 0, 0])
            else:
                raw += bytes([0, 0, 255, 255])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def main(rt, api, output):
    javac = shutil.which("javac") or "javac"
    with tempfile.TemporaryDirectory() as tmp:
        stub_dir = os.path.join(tmp, "stub")
        os.makedirs(stub_dir)
        # javac needs to see OldCode as a class; the real one replaces it in the JAR.
        stub = os.path.join(stub_dir, "OldCode.java")
        with open(stub, "w") as f:
            f.write("public class OldCode { public static int compute() { return 0; } }\n")
        classes = os.path.join(tmp, "classes")
        os.makedirs(classes)
        subprocess.check_call([javac, "-source", "8", "-target", "8", "-bootclasspath", api + os.pathsep + rt, "-nowarn", "-encoding", "UTF-8",
                               "-d", classes,
                               os.path.join(HERE, "SelfTest.java"), stub])
        with open(os.path.join(classes, "OldCode.class"), "wb") as f:
            f.write(old_code_class())
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("META-INF/MANIFEST.MF",
                       "Manifest-Version: 1.0\r\nMIDlet-Name: KUONTPL SelfTest\r\nMIDlet-Version: 1.0\r\n"
                       "MIDlet-Vendor: JarBox\r\nMIDlet-1: SelfTest,,SelfTest\r\nSelfTest-Key: SelfValue\r\n"
                       "MicroEdition-Profile: MIDP-2.0\r\nMicroEdition-Configuration: CLDC-1.1\r\n\r\n")
            z.writestr("test.png", test_png())
            for root, _, names in os.walk(classes):
                for n in names:
                    path = os.path.join(root, n)
                    z.write(path, os.path.relpath(path, classes).replace(os.sep, "/"))
    print("Built", output)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
