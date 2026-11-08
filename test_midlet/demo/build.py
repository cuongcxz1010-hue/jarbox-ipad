#!/usr/bin/env python3
"""Build demo.jar. Usage: build.py <minijvm_rt.jar> <j2me_api.jar> <output.jar>"""
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main(rt, api, output):
    javac = shutil.which("javac") or "javac"
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.check_call([javac, "-source", "8", "-target", "8", "-bootclasspath", api + os.pathsep + rt, "-nowarn", "-encoding", "UTF-8",
                               "-d", tmp, os.path.join(HERE, "Demo.java")])
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("META-INF/MANIFEST.MF",
                       "Manifest-Version: 1.0\r\nMIDlet-Name: JarBox Demo\r\nMIDlet-Version: 1.0\r\n"
                       "MIDlet-Vendor: JarBox\r\nMIDlet-1: Demo,,Demo\r\n\r\n")
            for root, _, names in os.walk(tmp):
                for n in names:
                    path = os.path.join(root, n)
                    z.write(path, os.path.relpath(path, tmp).replace(os.sep, "/"))
    print("Built", output)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
