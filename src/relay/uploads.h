#pragma once
#include <stddef.h>
#include <stdint.h>

/* Operations stay beneath an already-open private upload root. */
int zr_upload_directory(int root, const char *id);
int zr_upload_temporary(int directory, const char *name);
int zr_upload_write(int fd, const void *bytes, size_t length);
int zr_upload_install(int directory, int fd, const char *temporary, const char *name, uint64_t length);
int zr_upload_open(int root, const char *id, const char *name, uint64_t length);
/* Remove a single upload directory without following symlinks. Absence succeeds. */
int zr_upload_remove(int root, const char *id);
