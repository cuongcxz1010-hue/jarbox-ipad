//
//  archive.c
//  JarBox — ZIP backup and restore of game data, using the bundled miniz.
//

#include "Storage/archive.h"
#include "../minijvm/utils/miniz.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#if defined(_WIN32)
#include <direct.h>
#define MAKE_DIR(p) _mkdir(p)
#else
#define MAKE_DIR(p) mkdir((p), 0755)
#endif

static int add_directory(mz_zip_archive *zip, const char *path, const char *prefix) {
    DIR *dir = opendir(path);
    if (!dir) return 0;
    int ok = 1;
    struct dirent *entry;
    while (ok && (entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char full[2048], name[2048];
        snprintf(full, sizeof full, "%s/%s", path, entry->d_name);
        snprintf(name, sizeof name, "%s%s", prefix, entry->d_name);
        struct stat st;
        if (stat(full, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            strncat(name, "/", sizeof name - strlen(name) - 1);
            ok = add_directory(zip, full, name);
        } else {
            ok = mz_zip_writer_add_file(zip, name, full, NULL, 0, MZ_DEFAULT_COMPRESSION);
        }
    }
    closedir(dir);
    return ok;
}

int jarbox_zip_directory(const char *directory, const char *zipPath) {
    mz_zip_archive zip;
    memset(&zip, 0, sizeof zip);
    remove(zipPath);
    if (!mz_zip_writer_init_file(&zip, zipPath, 0)) return 0;
    int ok = add_directory(&zip, directory, "");
    if (ok) ok = mz_zip_writer_finalize_archive(&zip);
    mz_zip_writer_end(&zip);
    if (!ok) remove(zipPath);
    return ok;
}

static void make_parents(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            MAKE_DIR(path);
            *p = '/';
        }
    }
}

/// Reject names that would escape the destination.
static int safe_name(const char *name) {
    if (name[0] == '/' || name[0] == '\\') return 0;
    return strstr(name, "..") == NULL;
}

int jarbox_unzip(const char *zipPath, const char *directory) {
    mz_zip_archive zip;
    memset(&zip, 0, sizeof zip);
    if (!mz_zip_reader_init_file(&zip, zipPath, 0)) return 0;
    MAKE_DIR(directory);
    int ok = 1;
    mz_uint n = mz_zip_reader_get_num_files(&zip);
    for (mz_uint i = 0; ok && i < n; i++) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&zip, i, &st)) { ok = 0; break; }
        if (!safe_name(st.m_filename)) continue;
        char out[2048];
        snprintf(out, sizeof out, "%s/%s", directory, st.m_filename);
        make_parents(out);
        if (mz_zip_reader_is_file_a_directory(&zip, i)) {
            MAKE_DIR(out);
        } else {
            ok = mz_zip_reader_extract_to_file(&zip, i, out, 0);
        }
    }
    mz_zip_reader_end(&zip);
    return ok;
}
