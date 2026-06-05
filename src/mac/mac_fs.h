/* mac_fs.h — macOS filesystem helpers (trash/delete) for NppFTP. */
#ifndef NPPFTP_MAC_FS_H
#define NPPFTP_MAC_FS_H
#ifdef __cplusplus
extern "C" {
#endif
// Delete a file or directory tree. If permanent is false, move it to the Trash
// (recycle bin); otherwise delete it outright. Returns 0 on success.
int MacRecycleOrDeletePath(const char* path, int permanent);
#ifdef __cplusplus
}
#endif
#endif
