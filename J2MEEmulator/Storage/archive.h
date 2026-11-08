#ifndef JARBOX_ARCHIVE_H
#define JARBOX_ARCHIVE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Write every file under `directory` to a ZIP archive. Returns 1 on success.
int jarbox_zip_directory(const char *directory, const char *zipPath);

/// Extract a ZIP archive into `directory`. Returns 1 on success.
int jarbox_unzip(const char *zipPath, const char *directory);

#ifdef __cplusplus
}
#endif

#endif /* JARBOX_ARCHIVE_H */
