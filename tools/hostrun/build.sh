#!/bin/bash
# Build the desktop test host, on Windows, with `zig cc`.
#   tools/hostrun/build.sh <path to zig.exe> <output dir without spaces>
# Objects are cached in <output dir>/obj; only changed sources are rebuilt.
set -e

ZIG="$1"
OUT="$2"
cd "$(dirname "$0")/../.."      # the repository path may contain spaces; use relative paths

SRC=J2MEEmulator
JVM=$SRC/minijvm
mkdir -p "$OUT/obj" "$OUT/res"

CFLAGS="-target x86_64-windows-gnu -O2 -g0 -w -std=gnu11 -D__JVM_OS_MINGW__=1 -DJIT_ENABLE=0
  -I$JVM -I$JVM/jvm -I$JVM/utils -I$JVM/utils/https -I$JVM/utils/https/mbedtls/include
  -I$SRC -I$SRC/NativeBridge -I$SRC/Engine -Itools/hostrun"

compile() {
    local src="$1"
    local obj="$OUT/obj/$(echo "$src" | sed 's|[/:]|_|g').o"
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ] || [ -n "$FORCE" ]; then
        "$ZIG" cc $CFLAGS -c "$src" -o "$obj" 2>&1 | grep -E "error" || true
    fi
}
export -f compile
export ZIG CFLAGS OUT FORCE

ls $JVM/jvm/*.c $JVM/utils/*.c $JVM/utils/https/*.c $JVM/utils/https/mbedtls/library/*.c \
   $SRC/Engine/*.c $SRC/NativeBridge/j2me_input.c $SRC/NativeBridge/jvm_bridge.c \
   tools/hostrun/*.c | xargs -P 8 -I{} bash -c 'compile "{}"'

"$ZIG" cc -target x86_64-windows-gnu -O2 -g0 -o "$OUT/hostrun.exe" "$OUT"/obj/*.o -lws2_32 -lwsock32 -lbcrypt -ladvapi32
echo "Built $OUT/hostrun.exe"
