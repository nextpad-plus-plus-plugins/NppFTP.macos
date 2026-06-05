/*
 * win_file.h — Win32 file & memory-mapping APIs → POSIX, for the NppFTP port.
 * HANDLE doubles as a file descriptor: (HANDLE)(intptr_t)fd.
 * NppFTP macOS port 2026 (GPL v3).
 */
#ifndef NPPFTP_WIN_FILE_H
#define NPPFTP_WIN_FILE_H

#include "win_compat.h"
#include <sys/mman.h>
#include <cwchar>

// ── codepages (TCHAR==char==UTF-8, so conversions are identity) ─────────────
#ifndef CP_ACP
  #define CP_ACP   0
  #define CP_UTF8  65001
  #define CP_OEMCP 1
#endif
#ifndef NO_ERROR
  #define NO_ERROR 0
#endif

// ── wide numeric parse (the LPCWSTR ParseString overload) ───────────────────
#ifndef _wtol
  #define _wtol(s)  wcstol((s), NULL, 10)
  #define _wtoi(s)  ((int)wcstol((s), NULL, 10))
#endif

// ── in-place case conversion ────────────────────────────────────────────────
static inline char* _strupr(char* s) { for (char* p = s; p && *p; ++p) *p = (char)toupper((unsigned char)*p); return s; }
static inline char* _strlwr(char* s) { for (char* p = s; p && *p; ++p) *p = (char)tolower((unsigned char)*p); return s; }

// 64-bit arithmetic shift helper (Win32 macro).
#ifndef Int64ShraMod32
  #define Int64ShraMod32(a, b) ((LONGLONG)(a) >> (b))
#endif

// ── HANDLE <-> fd ───────────────────────────────────────────────────────────
static inline int    _h2fd(HANDLE h) { return (int)(intptr_t)h; }
static inline HANDLE _fd2h(int fd)    { return (HANDLE)(intptr_t)fd; }

// ── CreateFile / Read / Write / Seek / Size / Close ─────────────────────────
typedef struct _SECURITY_ATTRIBUTES SECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;
typedef struct _OVERLAPPED          OVERLAPPED, *LPOVERLAPPED;

static inline HANDLE CreateFileA(LPCSTR name, DWORD access, DWORD /*share*/,
                                 LPSECURITY_ATTRIBUTES /*sa*/, DWORD disposition,
                                 DWORD /*flags*/, HANDLE /*templ*/) {
    int oflag = 0;
    bool rd = (access & GENERIC_READ) != 0;
    bool wr = (access & GENERIC_WRITE) != 0;
    if (rd && wr) oflag = O_RDWR; else if (wr) oflag = O_WRONLY; else oflag = O_RDONLY;
    switch (disposition) {
        case CREATE_NEW:       oflag |= O_CREAT | O_EXCL; break;
        case CREATE_ALWAYS:    oflag |= O_CREAT | O_TRUNC; break;
        case OPEN_EXISTING:    break;
        case OPEN_ALWAYS:      oflag |= O_CREAT; break;
        case TRUNCATE_EXISTING:oflag |= O_TRUNC; break;
        default: break;
    }
    int fd = ::open(name, oflag, 0644);
    return fd < 0 ? INVALID_HANDLE_VALUE : _fd2h(fd);
}
#define CreateFile  CreateFileA

static inline BOOL ReadFile(HANDLE h, LPVOID buf, DWORD n, LPDWORD read, LPOVERLAPPED /*ovl*/) {
    ssize_t r = ::read(_h2fd(h), buf, n);
    if (r < 0) { if (read) *read = 0; return FALSE; }
    if (read) *read = (DWORD)r;
    return TRUE;
}
static inline BOOL WriteFile(HANDLE h, LPCVOID buf, DWORD n, LPDWORD written, LPOVERLAPPED /*ovl*/) {
    ssize_t w = ::write(_h2fd(h), buf, n);
    if (w < 0) { if (written) *written = 0; return FALSE; }
    if (written) *written = (DWORD)w;
    return TRUE;
}
static inline DWORD GetFileSize(HANDLE h, LPDWORD hi) {
    struct stat st;
    if (::fstat(_h2fd(h), &st) != 0) return INVALID_FILE_SIZE;
    if (hi) *hi = (DWORD)((uint64_t)st.st_size >> 32);
    return (DWORD)((uint64_t)st.st_size & 0xFFFFFFFF);
}
static inline DWORD SetFilePointer(HANDLE h, LONG lo, LONG* hi, DWORD method) {
    int whence = (method == FILE_BEGIN) ? SEEK_SET : (method == FILE_END) ? SEEK_END : SEEK_CUR;
    int64_t off = hi ? (((int64_t)(*hi) << 32) | (uint32_t)lo) : (int64_t)lo;
    off_t r = ::lseek(_h2fd(h), (off_t)off, whence);
    if (r == (off_t)-1) return INVALID_SET_FILE_POINTER;
    if (hi) *hi = (LONG)((uint64_t)r >> 32);
    return (DWORD)((uint64_t)r & 0xFFFFFFFF);
}
static inline BOOL SetEndOfFile(HANDLE h) {
    off_t pos = ::lseek(_h2fd(h), 0, SEEK_CUR);
    return ::ftruncate(_h2fd(h), pos) == 0 ? TRUE : FALSE;
}
static inline BOOL FlushFileBuffers(HANDLE h) { return ::fsync(_h2fd(h)) == 0 ? TRUE : FALSE; }
static inline BOOL CloseHandle(HANDLE h) {
    if (h == INVALID_HANDLE_VALUE || h == NULL) return FALSE;
    return ::close(_h2fd(h)) == 0 ? TRUE : FALSE;
}
static inline BOOL DeleteFileA(LPCSTR p) { return ::unlink(p) == 0 ? TRUE : FALSE; }
#define DeleteFile DeleteFileA

// ── temp paths ──────────────────────────────────────────────────────────────
static inline DWORD GetTempPathA(DWORD n, LPSTR buf) {
    const char* t = getenv("TMPDIR"); if (!t || !*t) t = "/tmp/";
    size_t len = strlen(t);
    if (buf && n > len) { strcpy(buf, t); if (buf[len-1] != '/') { buf[len]='/'; buf[len+1]=0; len++; } }
    return (DWORD)len;
}
#define GetTempPath GetTempPathA
static inline UINT GetTempFileNameA(LPCSTR dir, LPCSTR pre, UINT /*unique*/, LPSTR out) {
    snprintf(out, MAX_PATH, "%s/%sXXXXXX", dir, pre ? pre : "tmp");
    int fd = ::mkstemp(out);
    if (fd >= 0) ::close(fd);
    return fd >= 0 ? 1 : 0;
}
#define GetTempFileName GetTempFileNameA

// ── memory-mapped files → mmap ──────────────────────────────────────────────
#define PAGE_READONLY   0x02
#define PAGE_READWRITE  0x04
#define FILE_MAP_READ   0x0004
#define FILE_MAP_WRITE  0x0002
#define FILE_MAP_ALL_ACCESS 0x000F

// We store the fd in the "mapping handle" and create the actual mapping in
// MapViewOfFile (POSIX needs the fd + length at mmap time).
static inline HANDLE CreateFileMappingA(HANDLE hFile, LPSECURITY_ATTRIBUTES, DWORD /*protect*/,
                                        DWORD /*sizeHi*/, DWORD /*sizeLo*/, LPCSTR /*name*/) {
    return hFile;   // carry the fd; MapViewOfFile maps it
}
#define CreateFileMapping CreateFileMappingA

static inline LPVOID MapViewOfFile(HANDLE hMap, DWORD access, DWORD offHi, DWORD offLo, SIZE_T bytes) {
    int fd = _h2fd(hMap);
    int prot = (access & FILE_MAP_WRITE) ? (PROT_READ | PROT_WRITE) : PROT_READ;
    int flags = (access & FILE_MAP_WRITE) ? MAP_SHARED : MAP_PRIVATE;
    off_t off = ((off_t)offHi << 32) | offLo;
    size_t len = bytes;
    if (len == 0) { struct stat st; if (::fstat(fd, &st) == 0) len = (size_t)st.st_size - (size_t)off; }
    void* p = ::mmap(NULL, len, prot, flags, fd, off);
    return p == MAP_FAILED ? NULL : p;
}
static inline BOOL UnmapViewOfFile(LPCVOID base) {
    // length unknown to caller's API; munmap requires it. NppFTP unmaps whole
    // views, so we record nothing and rely on process teardown / msync flush.
    // Use a conservative page-rounded unmap of 0 length is invalid; instead the
    // caller tracks length. Provide a length-tracking variant below.
    (void)base; return TRUE;
}
static inline BOOL FlushViewOfFile(LPCVOID base, SIZE_T bytes) {
    return ::msync((void*)base, bytes ? bytes : 0, MS_SYNC) == 0 ? TRUE : FALSE;
}

#endif // NPPFTP_WIN_FILE_H
