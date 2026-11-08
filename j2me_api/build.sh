#!/bin/bash
# Build j2me_api.jar — minimal J2ME API for iOS/miniJVM
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../J2MEEmulator/Resources/jars"
# Prefer a freshly built miniJVM runtime; fall back to the copy shipped in the repo
MINIJVM_RT="$SCRIPT_DIR/../../miniJVM-2.0.0/binary/lib/minijvm_rt.jar"
if [ ! -f "$MINIJVM_RT" ]; then
    MINIJVM_RT="$OUTPUT_DIR/minijvm_rt.jar"
fi

if ! command -v javac &> /dev/null; then
    if [ -f /opt/homebrew/opt/openjdk/bin/javac ]; then
        export PATH="/opt/homebrew/opt/openjdk/bin:$PATH"
    else
        echo "ERROR: javac not found"; exit 1
    fi
fi

if [ ! -f "$MINIJVM_RT" ]; then
    echo "ERROR: minijvm_rt.jar not found at $MINIJVM_RT"
    exit 1
fi

echo "Building j2me_api.jar..."

rm -rf "$SCRIPT_DIR/classes"
mkdir -p "$SCRIPT_DIR/classes"
mkdir -p "$OUTPUT_DIR"

find "$SCRIPT_DIR/src" -name "*.java" > "$SCRIPT_DIR/sources.txt"

# Against the real runtime, not the JDK's class library: calling something the
# runtime lacks must be a compile error here, not a NoSuchMethodError on the device.
javac -source 8 -target 8 \
    -bootclasspath "$MINIJVM_RT" \
    -encoding UTF-8 \
    -nowarn \
    -d "$SCRIPT_DIR/classes" \
    @"$SCRIPT_DIR/sources.txt"

jar cf "$OUTPUT_DIR/j2me_api.jar" -C "$SCRIPT_DIR/classes" .

rm -f "$SCRIPT_DIR/sources.txt"
echo "Built: $OUTPUT_DIR/j2me_api.jar"
