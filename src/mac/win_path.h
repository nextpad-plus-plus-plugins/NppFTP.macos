/*
 * win_path.h — shlwapi Path* helpers → POSIX, for the NppFTP port.
 * These operate on LOCAL filesystem paths (TCHAR==char, '/' separator on macOS).
 * NppFTP's own FTP-path logic lives in PathUtils and uses '/' already.
 * NppFTP macOS port 2026 (GPL v3).
 */
#ifndef NPPFTP_WIN_PATH_H
#define NPPFTP_WIN_PATH_H

#include "win_compat.h"
#include <limits.h>

static inline LPSTR PathFindFileNameA(LPCSTR path) {
    const char* slash = strrchr(path, '/');
    return (LPSTR)(slash ? slash + 1 : path);
}
#define PathFindFileName PathFindFileNameA

static inline BOOL PathIsDirectoryA(LPCSTR path) {
    struct stat st;
    return (::stat(path, &st) == 0 && S_ISDIR(st.st_mode)) ? TRUE : FALSE;
}
#define PathIsDirectory PathIsDirectoryA

// Remove a single trailing '/'. Returns pointer to the NUL (Win32 returns the
// address of the removed char / end).
static inline LPSTR PathRemoveBackslashA(LPSTR path) {
    size_t n = strlen(path);
    if (n > 1 && path[n - 1] == '/') { path[n - 1] = 0; return path + n - 1; }
    return path + n;
}
#define PathRemoveBackslash PathRemoveBackslashA

// Combine dir + file into dest (dest may alias dir). Returns dest.
static inline LPSTR PathCombineA(LPSTR dest, LPCSTR dir, LPCSTR file) {
    char tmp[PATH_MAX * 2];
    if (file && file[0] == '/') {                 // file is absolute
        snprintf(tmp, sizeof(tmp), "%s", file);
    } else if (dir && dir[0]) {
        size_t dl = strlen(dir);
        if (dl && dir[dl - 1] == '/') snprintf(tmp, sizeof(tmp), "%s%s", dir, file ? file : "");
        else                         snprintf(tmp, sizeof(tmp), "%s/%s", dir, file ? file : "");
    } else {
        snprintf(tmp, sizeof(tmp), "%s", file ? file : "");
    }
    strcpy(dest, tmp);
    return dest;
}
#define PathCombine PathCombineA

// Append a component to path in-place. Returns TRUE.
static inline BOOL PathAppendA(LPSTR path, LPCSTR more) {
    char tmp[PATH_MAX * 2];
    PathCombineA(tmp, path, more);
    strcpy(path, tmp);
    return TRUE;
}
#define PathAppend PathAppendA

// Qualify (make absolute) src into buf (buf >= MAX_PATH). Returns TRUE.
static inline BOOL PathSearchAndQualifyA(LPCSTR src, LPSTR buf, UINT cchBuf) {
    if (src && src[0] == '/') {
        snprintf(buf, cchBuf, "%s", src);
    } else {
        char cwd[PATH_MAX];
        if (!getcwd(cwd, sizeof(cwd))) cwd[0] = 0;
        snprintf(buf, cchBuf, "%s/%s", cwd, src ? src : "");
    }
    return TRUE;
}
#define PathSearchAndQualify PathSearchAndQualifyA

// TRUE if path ends with any of the given suffixes (case-insensitive, Win32-like).
static inline LPCSTR PathFindSuffixArrayA(LPCSTR path, const LPCSTR* suffixes, int count) {
    size_t pl = strlen(path);
    for (int i = 0; i < count; i++) {
        size_t sl = strlen(suffixes[i]);
        if (pl >= sl && strcasecmp(path + pl - sl, suffixes[i]) == 0)
            return suffixes[i];
    }
    return NULL;
}
#define PathFindSuffixArray PathFindSuffixArrayA

// Length (in chars) of the common path prefix of p1 and p2; copies it to common.
static inline int PathCommonPrefixA(LPCSTR p1, LPCSTR p2, LPSTR common) {
    int i = 0, lastSlash = 0;
    while (p1[i] && p2[i] && p1[i] == p2[i]) { if (p1[i] == '/') lastSlash = i; i++; }
    if (!p1[i] && !p2[i]) lastSlash = i;                 // identical
    else if ((!p1[i] && p2[i] == '/') || (!p2[i] && p1[i] == '/')) lastSlash = i;
    if (common) { memcpy(common, p1, lastSlash); common[lastSlash] = 0; }
    return lastSlash;
}
#define PathCommonPrefix PathCommonPrefixA

// Recursive mkdir -p (Win32 SHCreateDirectoryEx). Returns ERROR_SUCCESS / errno.
static inline int SHCreateDirectoryExA(HWND, LPCSTR path, const void*) {
    char tmp[PATH_MAX]; snprintf(tmp, sizeof(tmp), "%s", path);
    for (char* p = tmp + 1; *p; ++p) {
        if (*p == '/') { *p = 0; ::mkdir(tmp, 0755); *p = '/'; }
    }
    if (::mkdir(tmp, 0755) == 0) return 0;
    return (errno == EEXIST) ? 183 /*ERROR_ALREADY_EXISTS*/ : errno;
}
#define SHCreateDirectoryEx SHCreateDirectoryExA

#endif // NPPFTP_WIN_PATH_H
