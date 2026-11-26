#include "EvergreenArchive.h"
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

// macOS ships libarchive and exports these stable functions without its headers in the SDK.
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip_seekable(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern int archive_read_data_block(struct archive *, const void **, size_t *, int64_t *);
extern int archive_read_free(struct archive *);
extern struct archive *archive_write_disk_new(void);
extern int archive_write_disk_set_options(struct archive *, int);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern ssize_t archive_write_data_block(struct archive *, const void *, size_t, int64_t);
extern int archive_write_finish_entry(struct archive *);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern void archive_entry_set_pathname(struct archive_entry *, const char *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern mode_t archive_entry_perm(struct archive_entry *);
extern void archive_entry_set_perm(struct archive_entry *, mode_t);
extern int64_t archive_entry_size(struct archive_entry *);
extern int archive_entry_size_is_set(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);

enum {
    ARCHIVE_OK = 0, ARCHIVE_EOF = 1,
    ARCHIVE_EXTRACT_SECURE_SYMLINKS = 0x0100,
    ARCHIVE_EXTRACT_SECURE_NODOTDOT = 0x0200,
};

static bool relative_path(const char *path, size_t depth) {
    if (!path || !*path || *path == '/') return false;
    while (*path) {
        size_t length = strcspn(path, "/");
        if (length == 2 && strncmp(path, "..", 2) == 0) {
            if (depth == 0) return false;
            depth--;
        } else if (length > 0 && !(length == 1 && *path == '.')) {
            depth++;
        }
        path += length;
        if (*path == '/') path++;
    }
    return true;
}

bool evergreen_extract_zip(const char *source, const char *destination) {
    const int64_t size_limit = INT64_C(8) * 1024 * 1024 * 1024;
    struct archive *reader = archive_read_new();
    struct archive *writer = archive_write_disk_new();
    bool success = false;
    if (!reader || !writer ||
        archive_read_support_format_zip_seekable(reader) != ARCHIVE_OK ||
        archive_read_open_filename(reader, source, 65536) != ARCHIVE_OK ||
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_SECURE_SYMLINKS |
                                               ARCHIVE_EXTRACT_SECURE_NODOTDOT) != ARCHIVE_OK) goto cleanup;

    struct archive_entry *entry;
    int status;
    int64_t expanded = 0;
    unsigned entry_count = 0;
    while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        const char *path = archive_entry_pathname(entry);
        mode_t type = archive_entry_filetype(entry);
        int64_t size = archive_entry_size(entry);
        const char *link = archive_entry_symlink(entry);
        if (++entry_count > 200000 || !relative_path(path, 0) || archive_entry_hardlink(entry) ||
            archive_entry_is_encrypted(entry) > 0 ||
            (type != S_IFREG && type != S_IFDIR && type != S_IFLNK)) goto cleanup;

        // Reject every parent component in entry names, even paths which resolve within the archive.
        size_t depth = 0;
        for (const char *component = path; *component;) {
            size_t length = strcspn(component, "/");
            if (length == 2 && strncmp(component, "..", 2) == 0) goto cleanup;
            if (component[length] == '/' && length > 0 && !(length == 1 && *component == '.')) depth++;
            component += length;
            if (*component == '/') component++;
        }
        // Frameworks use relative links within the bundle. A link may not climb above its top-level app.
        if (type == S_IFLNK && (depth == 0 || !relative_path(link, depth - 1))) goto cleanup;
        if (type == S_IFREG && (!archive_entry_size_is_set(entry) || size < 0 || size > size_limit - expanded)) goto cleanup;

        char target[PATH_MAX];
        int length = snprintf(target, sizeof(target), "%s/%s", destination, path);
        if (length < 0 || (size_t)length >= sizeof(target)) goto cleanup;
        archive_entry_set_pathname(entry, target);
        archive_entry_set_perm(entry, archive_entry_perm(entry) & 0777);
        if (archive_write_header(writer, entry) != ARCHIVE_OK) goto cleanup;
        if (type == S_IFREG) {
            const void *buffer;
            size_t count;
            int64_t offset;
            while ((status = archive_read_data_block(reader, &buffer, &count, &offset)) == ARCHIVE_OK) {
                if (offset < 0 || offset > size || count > (uint64_t)(size - offset) ||
                    archive_write_data_block(writer, buffer, count, offset) < 0) goto cleanup;
            }
            if (status != ARCHIVE_EOF) goto cleanup;
            expanded += size;
        }
        if (archive_write_finish_entry(writer) != ARCHIVE_OK) goto cleanup;
    }
    success = status == ARCHIVE_EOF && entry_count > 0 && archive_write_close(writer) == ARCHIVE_OK;

cleanup:
    if (reader) archive_read_free(reader);
    if (writer) archive_write_free(writer);
    return success;
}
