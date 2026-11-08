// Windows implementations of miniJVM's os_* services, for the desktop test host only.
// (The iOS app uses os_posix.c.)

#include <stdio.h>
#include <string.h>
#include <direct.h>
#include <windows.h>
#include "jvm.h"
#include "jvm_util.h"

s32 os_execute(Runtime *runtime, Instance *jstrArr, Instance *jlongArr, ArrayList *cstrList, const c8 *cmd) { return -1; }
s32 os_kill_process(s64 pid) { return 0; }
s32 os_waitfor_process(Runtime *runtime, s64 pid, s64 tid, s32 *pExitCode) { return -1; }

Utf8String *os_get_tmp_dir() {
    Utf8String *u = utf8_create();
    utf8_append_c(u, "C:/Windows/Temp");
    return u;
}

void os_set_file_length(FILE *file, s64 len) {
    _chsize_s(_fileno(file), len);
}

s32 os_mkdir(const c8 *path) { return _mkdir(path); }
s32 os_iswin() { return 1; }
s32 os_fileno(FILE *fd) { return _fileno(fd); }

s32 os_append_libname(Utf8String *libname, const c8 *lib) {
    utf8_append_c(libname, lib);
    return 0;
}

s32 os_load_lib_and_init(const c8 *libname, Runtime *runtime) { return -1; }

s32 conv_utf8_2_platform_encoding(ByteBuf *dst, Utf8String *src) {
    if (!dst || !src) return -1;
    s32 n = src->length;
    bytebuf_expand(dst, n + 1);
    memcpy(dst->buf, src->data, n);
    dst->buf[n] = 0;
    return n;
}

s32 conv_platform_encoding_2_utf8(Utf8String *dst, const c8 *src) {
    if (!dst || !src) return -1;
    utf8_clear(dst);
    utf8_append_c(dst, src);
    return dst->length;
}

void os_get_lang(Utf8String *buf) { utf8_append_c(buf, "en"); }
void os_get_uuid(MiniJVM *jvm, Utf8String *buf) { utf8_append_c(buf, "00000000-0000-0000-0000-000000000000"); }
