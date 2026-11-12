#!/usr/bin/env python3
"""Build demo.jar and bench.jar next to each other.
Usage: build.py <minijvm_rt.jar> <j2me_api.jar> <output demo.jar>"""
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def build(rt, api, source, main, output):
    javac = shutil.which("javac") or "javac"
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.check_call([javac, "-source", "8", "-target", "8", "-bootclasspath", api + os.pathsep + rt, "-nowarn",
                               "-encoding", "UTF-8", "-d", tmp, os.path.join(HERE, source)],
                              stderr=subprocess.DEVNULL)
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("META-INF/MANIFEST.MF",
                       "Manifest-Version: 1.0\r\nMIDlet-Name: KUONTPL %s\r\nMIDlet-Version: 1.0\r\n"
                       "MIDlet-Vendor: JarBox\r\nMIDlet-1: %s,,%s\r\n\r\n" % (main, main, main))
            for root, _, names in os.walk(tmp):
                for n in names:
                    path = os.path.join(root, n)
                    z.write(path, os.path.relpath(path, tmp).replace(os.sep, "/"))
    print("Built", output)


if __name__ == "__main__":
    rt, api, output = sys.argv[1:4]
    build(rt, api, "Demo.java", "Demo", output)
    build(rt, api, "Bench.java", "Bench", os.path.join(os.path.dirname(output), "bench.jar"))
