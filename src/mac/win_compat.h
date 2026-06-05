/*
 * win_compat.h — Win32 → macOS/POSIX compatibility shim for the NppFTP port.
 *
 * NppFTP's engine (core src/ + UTCP) is Win32 C++ (TCHAR, Winsock, Win32 file/
 * thread APIs). Rather than de-Win32 every file, this header maps the (small,
 * inventoried) Win32 surface the ENGINE uses onto POSIX/BSD equivalents.
 *
 * Crucially we build NON-UNICODE: TCHAR == char (UTF-8). That collapses NppFTP's
 * UTF-16<->char conversions into near-identities and makes the FTP byte protocol
 * and local UTF-8 paths the same string type.
 *
 * UI (HWND/PostMessage/dialogs) is NOT emulated here — it is replaced by Cocoa.
 * The few engine->UI notifications go through an explicit callback (see the
 * notify shim), not Win32 messages.
 *
 * NppFTP macOS port 2026 (GPL v3, as upstream).
 */
#ifndef NPPFTP_WIN_COMPAT_H
#define NPPFTP_WIN_COMPAT_H

#if defined(_WIN32)
#error "win_compat.h is the macOS shim; do not use on Windows"
#endif

// ── POSIX / BSD system headers (replacing winsock2.h/windows.h) ─────────────
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <ctime>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <strings.h>          // strcasecmp / strncasecmp
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <sys/ioctl.h>     // FIONREAD

// ── calling-convention / pointer macros (no-ops on macOS) ───────────────────
#ifndef FAR
  #define FAR
#endif
#ifndef NEAR
  #define NEAR
#endif
#ifndef WINAPI
  #define WINAPI
#endif
#ifndef CALLBACK
  #define CALLBACK
#endif
#ifndef APIENTRY
  #define APIENTRY
#endif
#ifndef PASCAL
  #define PASCAL
#endif
#ifndef NULL
  #define NULL 0
#endif

// ── basic integer / boolean types ───────────────────────────────────────────
typedef int                 BOOL;
#ifndef TRUE
  #define TRUE  1
#endif
#ifndef FALSE
  #define FALSE 0
#endif

typedef uint8_t             BYTE;
typedef uint16_t            WORD;
typedef uint32_t            DWORD;
typedef uint32_t            ULONG;   // Win32 LLP64: long is 32-bit
typedef unsigned int        UINT;
typedef int32_t             LONG;    // Win32 LLP64: long is 32-bit
typedef int64_t             LONGLONG;
typedef uint64_t            ULONGLONG;

typedef void*               LPVOID;
typedef const void*         LPCVOID;
typedef uintptr_t           WPARAM;
typedef intptr_t            LPARAM;
typedef intptr_t            LRESULT;
typedef int32_t             HRESULT;
#ifndef S_OK
  #define S_OK    ((HRESULT)0)
  #define E_FAIL  ((HRESULT)0x80004005)
#endif

// Opaque handles. HANDLE doubles as a file descriptor holder (see win_file.h).
typedef void*               HANDLE;
typedef void*               HMODULE;
typedef void*               HINSTANCE;
typedef void*               HWND;          // engine only uses it as an opaque notify target
#define INVALID_HANDLE_VALUE  ((HANDLE)(intptr_t)-1)

// ── characters: NON-UNICODE → TCHAR == char (UTF-8) ─────────────────────────
typedef char                TCHAR;
typedef char                _TCHAR;
typedef char*               LPSTR;
typedef const char*         LPCSTR;
typedef char*               LPTSTR;
typedef const char*         LPCTSTR;
typedef wchar_t*            LPWSTR;
typedef const wchar_t*      LPCWSTR;
#ifndef _T
  #define _T(x)   x
#endif
#ifndef TEXT
  #define TEXT(x) x
#endif

#ifndef MAX_PATH
  #define MAX_PATH 1024
#endif

typedef wchar_t             WCHAR;
typedef uint8_t             BOOLEAN;
typedef void*               HTREEITEM;   // UI tree handle (opaque to the engine)
typedef size_t              SIZE_T;
typedef intptr_t            LONG_PTR;
typedef uintptr_t           ULONG_PTR;
typedef uint16_t            ATOM;
typedef void*               HICON;
typedef void*               HCURSOR;
typedef void*               HBRUSH;
typedef void*               HMENU;
typedef BYTE*               LPBYTE;
typedef DWORD*              LPDWORD;
typedef WORD*               LPWORD;
typedef void*               PVOID;
typedef int*                LPINT;
typedef long*               LPLONG;

#ifndef UNREFERENCED_PARAMETER
  #define UNREFERENCED_PARAMETER(x) ((void)(x))
#endif
#ifndef MAXGETHOSTSTRUCT
  #define MAXGETHOSTSTRUCT 1024
#endif

// 64-bit split integer (file sizes / offsets)
typedef union _LARGE_INTEGER {
    struct { DWORD LowPart; LONG HighPart; } u;
    struct { DWORD LowPart; LONG HighPart; };
    LONGLONG QuadPart;
} LARGE_INTEGER;
typedef union _ULARGE_INTEGER {
    struct { DWORD LowPart; DWORD HighPart; } u;
    struct { DWORD LowPart; DWORD HighPart; };
    ULONGLONG QuadPart;
} ULARGE_INTEGER;

// ── CreateFile / SetFilePointer flags (for the HANDLE file-I/O shim) ────────
#define GENERIC_READ            0x80000000u
#define GENERIC_WRITE           0x40000000u
#define CREATE_NEW              1
#define CREATE_ALWAYS          2
#define OPEN_EXISTING          3
#define OPEN_ALWAYS            4
#define TRUNCATE_EXISTING      5
#define FILE_SHARE_READ         0x00000001
#define FILE_SHARE_WRITE        0x00000002
#define FILE_SHARE_DELETE       0x00000004
#define FILE_ATTRIBUTE_NORMAL   0x00000080
#define FILE_BEGIN              0
#define FILE_CURRENT            1
#define FILE_END                2
#define INVALID_FILE_SIZE        ((DWORD)0xFFFFFFFF)
#define INVALID_SET_FILE_POINTER ((DWORD)0xFFFFFFFF)

// ── sockets (Winsock names → BSD) ───────────────────────────────────────────
typedef int                 SOCKET;
typedef struct sockaddr     SOCKADDR;
typedef struct sockaddr*    LPSOCKADDR;
typedef struct sockaddr_in  SOCKADDR_IN;
typedef struct in_addr      IN_ADDR;
#ifndef INVALID_SOCKET
  #define INVALID_SOCKET    (-1)
#endif
#ifndef SOCKET_ERROR
  #define SOCKET_ERROR      (-1)
#endif
#ifndef closesocket
  #define closesocket(s)    ::close(s)
#endif
static inline int ioctlsocket(SOCKET s, long cmd, unsigned long* argp) {
    // FIONBIO is the only cmd NppFTP uses; map to fcntl O_NONBLOCK.
    int flags = ::fcntl(s, F_GETFL, 0);
    if (flags < 0) return SOCKET_ERROR;
    if (argp && *argp) flags |= O_NONBLOCK; else flags &= ~O_NONBLOCK;
    return ::fcntl(s, F_SETFL, flags) < 0 ? SOCKET_ERROR : 0;
    (void)cmd;
}

// Winsock startup/cleanup are no-ops on POSIX.
typedef struct { int unused; } WSADATA;
static inline int  WSAStartup(WORD, WSADATA*) { return 0; }
static inline int  WSACleanup(void) { return 0; }
static inline int  WSAGetLastError(void) { return errno; }
#define WSAGetLastError() (errno)

// Winsock error codes referenced by UTCP's error mapping. POSIX-equivalent
// codes map to errno; Windows-only ones get distinct sentinel values (they can
// never match a real errno, which is the correct behaviour).
#ifndef WSAEWOULDBLOCK
  #define WSAEINTR           EINTR
  #define WSAEACCES          EACCES
  #define WSAEFAULT          EFAULT
  #define WSAEINVAL          EINVAL
  #define WSAEMFILE          EMFILE
  #define WSAEWOULDBLOCK     EWOULDBLOCK
  #define WSAEINPROGRESS     EINPROGRESS
  #define WSAEALREADY        EALREADY
  #define WSAENOTSOCK        ENOTSOCK
  #define WSAEDESTADDRREQ    EDESTADDRREQ
  #define WSAEMSGSIZE        EMSGSIZE
  #define WSAEPROTOTYPE      EPROTOTYPE
  #define WSAENOPROTOOPT     ENOPROTOOPT
  #define WSAEPROTONOSUPPORT EPROTONOSUPPORT
  #define WSAESOCKTNOSUPPORT ESOCKTNOSUPPORT
  #define WSAEOPNOTSUPP      EOPNOTSUPP
  #define WSAEPFNOSUPPORT    EPFNOSUPPORT
  #define WSAEAFNOSUPPORT    EAFNOSUPPORT
  #define WSAEADDRINUSE      EADDRINUSE
  #define WSAEADDRNOTAVAIL   EADDRNOTAVAIL
  #define WSAENETDOWN        ENETDOWN
  #define WSAENETUNREACH     ENETUNREACH
  #define WSAENETRESET       ENETRESET
  #define WSAECONNABORTED    ECONNABORTED
  #define WSAECONNRESET      ECONNRESET
  #define WSAENOBUFS         ENOBUFS
  #define WSAEISCONN         EISCONN
  #define WSAENOTCONN        ENOTCONN
  #define WSAESHUTDOWN       ESHUTDOWN
  #define WSAETIMEDOUT       ETIMEDOUT
  #define WSAECONNREFUSED    ECONNREFUSED
  #define WSAEHOSTDOWN       EHOSTDOWN
  #define WSAEHOSTUNREACH    EHOSTUNREACH
  // Windows-only — sentinel values (match Win32 numeric codes, never == errno).
  #define WSAEDISCON            10101
  #define WSAEPROCLIM           10067
  #define WSANOTINITIALISED     10093
  #define WSASYSNOTREADY        10091
  #define WSAVERNOTSUPPORTED    10092
  #define WSASYSCALLFAILURE     10107
  #define WSATYPE_NOT_FOUND     10109
  #define WSAINVALIDPROCTABLE   10104
  #define WSAINVALIDPROVIDER    10105
  #define WSAPROVIDERFAILEDINIT 10106
  #define WSAHOST_NOT_FOUND     11001
  #define WSATRY_AGAIN          11002
  #define WSANO_RECOVERY        11003
  #define WSANO_DATA            11004
  #define WSA_INVALID_HANDLE       6
  #define WSA_INVALID_PARAMETER   87
  #define WSA_IO_INCOMPLETE      996
  #define WSA_IO_PENDING         997
  #define WSA_NOT_ENOUGH_MEMORY    8
  #define WSA_OPERATION_ABORTED  995
  // WSAAsyncSelect notification accessors (the async path is unused but must compile).
  #define WSAGETSELECTEVENT(lp)  LOWORD(lp)
  #define WSAGETSELECTERROR(lp)  HIWORD(lp)
  #define WSAGETASYNCERROR(lp)   HIWORD(lp)
#endif

// ── byte order / address helpers already POSIX (htons/ntohs/inet_*) ─────────
#ifndef HIBYTE
  #define HIBYTE(w)  ((BYTE)(((WORD)(w) >> 8) & 0xFF))
  #define LOBYTE(w)  ((BYTE)((WORD)(w) & 0xFF))
  #define HIWORD(l)  ((WORD)(((DWORD)(l) >> 16) & 0xFFFF))
  #define LOWORD(l)  ((WORD)((DWORD)(l) & 0xFFFF))
  #define MAKEWORD(a,b) ((WORD)(((BYTE)(a)) | (((WORD)((BYTE)(b))) << 8)))
#endif

// ── string functions ────────────────────────────────────────────────────────
#ifndef _snprintf
  #define _snprintf  snprintf
#endif
#ifndef _vsnprintf
  #define _vsnprintf vsnprintf
#endif
#ifndef _strnicmp
  #define _strnicmp  strncasecmp
#endif
#ifndef _stricmp
  #define _stricmp   strcasecmp
#endif
#ifndef stricmp
  #define stricmp    strcasecmp
#endif
#ifndef strnicmp
  #define strnicmp   strncasecmp
#endif
static inline int   lstrlenA(LPCSTR s) { return s ? (int)strlen(s) : 0; }
static inline LPSTR lstrcpyA(LPSTR d, LPCSTR s) { return strcpy(d, s); }
static inline LPSTR lstrcatA(LPSTR d, LPCSTR s) { return strcat(d, s); }
static inline int   lstrcmpA(LPCSTR a, LPCSTR b) { return strcmp(a, b); }
static inline int   lstrcmpiA(LPCSTR a, LPCSTR b) { return strcasecmp(a, b); }
#define lstrlen   lstrlenA
#define lstrcpy   lstrcpyA
#define lstrcat   lstrcatA
#define lstrcmp   lstrcmpA
#define lstrcmpi  lstrcmpiA

// MessageBox flags / return codes (the few NppFTP references; the actual
// MessageBox calls are in UI code, replaced by Cocoa alerts).
#ifndef MB_OK
  #define MB_OK              0x00000000
  #define MB_OKCANCEL        0x00000001
  #define MB_YESNO           0x00000004
  #define MB_ICONERROR       0x00000010
  #define MB_ICONQUESTION    0x00000020
  #define MB_ICONWARNING     0x00000030
  #define MB_ICONINFORMATION 0x00000040
  #define MB_DEFBUTTON1      0x00000000
  #define MB_DEFBUTTON2      0x00000100
  #define IDOK     1
  #define IDCANCEL 2
  #define IDYES    6
  #define IDNO     7
#endif

#ifndef Int32x32To64
  #define Int32x32To64(a, b) ((LONGLONG)(a) * (LONGLONG)(b))
  #define UInt32x32To64(a, b) ((ULONGLONG)(a) * (ULONGLONG)(b))
#endif
#ifndef ZeroMemory
  #define ZeroMemory(p, n)   memset((p), 0, (n))
  #define CopyMemory(d, s, n) memcpy((d), (s), (n))
  #define FillMemory(p, n, v) memset((p), (v), (n))
#endif
static inline LPTSTR lstrcpynA(LPTSTR dst, LPCTSTR src, int n) {
    if (n <= 0) return dst;
    strncpy(dst, src, (size_t)n - 1); dst[n - 1] = 0; return dst;
}
#define lstrcpyn lstrcpynA
// _tcs* family (TCHAR==char)
#define _tcslen   strlen
#define _tcscpy   strcpy
#define _tcsncpy  strncpy
#define _tcscat   strcat
#define _tcscmp   strcmp
#define _tcsicmp  strcasecmp
#define _tcsncmp  strncmp
#define _tcsnicmp strncasecmp
#define _tcschr   strchr
#define _tcsrchr  strrchr
#define _tcsstr   strstr
#define _tcstol   strtol
#define _tprintf  printf
#define _sntprintf snprintf
#define _vsntprintf vsnprintf
#define _ttoi     atoi
#define _tcsncat  strncat
#define _tcstok   strtok
#define _tgetenv  getenv
#define _vstprintf vsprintf
#define _vsprintf  vsprintf
#ifndef _fcvt
  #define _fcvt    fcvt
#endif
// int/long → string with radix (no itoa on macOS)
static inline char* _ltoa(long v, char* buf, int radix) {
    if (radix == 16)      sprintf(buf, "%lx", (unsigned long)v);
    else if (radix == 8)  sprintf(buf, "%lo", (unsigned long)v);
    else                  sprintf(buf, "%ld", v);
    return buf;
}
static inline char* _itoa(int v, char* buf, int radix) { return _ltoa((long)v, buf, radix); }
#define _itot _itoa
#define _ltot _ltoa
// Win32 _splitpath: split "dir/name.ext" into components (drive unused on POSIX).
static inline void _splitpath(const char* path, char* drive, char* dir, char* fname, char* ext) {
    if (drive) drive[0] = 0;
    const char* slash = strrchr(path, '/');
    const char* base  = slash ? slash + 1 : path;
    if (dir) {
        size_t dlen = slash ? (size_t)(slash - path + 1) : 0;
        memcpy(dir, path, dlen); dir[dlen] = 0;
    }
    const char* dot = strrchr(base, '.');
    if (fname) {
        size_t flen = dot ? (size_t)(dot - base) : strlen(base);
        memcpy(fname, base, flen); fname[flen] = 0;
    }
    if (ext) { if (dot) strcpy(ext, dot); else ext[0] = 0; }
}
#define _tsplitpath _splitpath

// ── CRITICAL_SECTION → recursive pthread mutex ──────────────────────────────
typedef pthread_mutex_t     CRITICAL_SECTION;
typedef pthread_mutex_t*    LPCRITICAL_SECTION;
static inline void InitializeCriticalSection(LPCRITICAL_SECTION cs) {
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(cs, &a);
    pthread_mutexattr_destroy(&a);
}
static inline void DeleteCriticalSection(LPCRITICAL_SECTION cs) { pthread_mutex_destroy(cs); }
static inline void EnterCriticalSection(LPCRITICAL_SECTION cs)  { pthread_mutex_lock(cs); }
static inline void LeaveCriticalSection(LPCRITICAL_SECTION cs)  { pthread_mutex_unlock(cs); }

// ── unused Win32 window / WSAAsyncSelect stubs ──────────────────────────────
// NppFTP's worker thread uses blocking sockets; UTCP's async-notify path (a
// hidden message window + WSAAsyncSelect) is never exercised. These stubs let
// those (virtual) functions compile/link unchanged; their bodies never run.
typedef intptr_t (*WNDPROC)(HWND, UINT, WPARAM, LPARAM);
typedef struct tagWNDCLASS {
    UINT     style;
    WNDPROC  lpfnWndProc;
    int      cbClsExtra;
    int      cbWndExtra;
    HINSTANCE hInstance;
    HICON    hIcon;
    HCURSOR  hCursor;
    HBRUSH   hbrBackground;
    LPCSTR   lpszMenuName;
    LPCSTR   lpszClassName;
} WNDCLASS;
#ifndef WM_USER
  #define WM_USER       0x0400
  #define WM_NCCREATE   0x0081
  #define WM_CREATE     0x0001
  #define WM_DESTROY    0x0002
#endif
static inline ATOM    RegisterClass(const WNDCLASS*) { return 0; }
static inline BOOL    GetClassInfo(HINSTANCE, LPCSTR, WNDCLASS*) { return FALSE; }
#define CreateWindow(...)            ((HWND)NULL)
#define CreateWindowEx(...)          ((HWND)NULL)
static inline BOOL    DestroyWindow(HWND) { return TRUE; }
#define DefWindowProc(h,m,w,l)       ((intptr_t)0)
static inline LONG_PTR SetWindowLongPtr(HWND, int, LONG_PTR) { return 0; }
static inline LONG_PTR GetWindowLongPtr(HWND, int) { return 0; }
static inline intptr_t SendMessage(HWND, UINT, WPARAM, LPARAM) { return 0; }
static inline int      WSAAsyncSelect(SOCKET, HWND, UINT, long) { return SOCKET_ERROR; }
static inline HANDLE   WSAAsyncGetHostByAddr(HWND, UINT, const char*, int, int, char*, int) { return NULL; }
static inline HANDLE   WSAAsyncGetHostByName(HWND, UINT, const char*, char*, int) { return NULL; }

// ── sleep / time ─────────────────────────────────────────────────────────────
// ── common Win32 ERROR_ codes ───────────────────────────────────────────────
#ifndef ERROR_SUCCESS
  #define ERROR_SUCCESS           0
  #define ERROR_FILE_NOT_FOUND    2
  #define ERROR_PATH_NOT_FOUND    3
  #define ERROR_ACCESS_DENIED     5
  #define ERROR_HANDLE_EOF        38
  #define ERROR_ALREADY_EXISTS    183
  #define ERROR_FILE_EXISTS       80
  #define ERROR_MORE_DATA         234
  #define ERROR_IO_PENDING        997
#endif

static inline void Sleep(DWORD ms) { ::usleep((useconds_t)ms * 1000); }
DWORD GetTickCount(void);           // monotonic ms (win_compat.cpp)
static inline DWORD GetLastError(void) { return (DWORD)errno; }
static inline void  SetLastError(DWORD e) { errno = (int)e; }

// ── Win32 time structs (file timestamps) ────────────────────────────────────
typedef struct _FILETIME {
    DWORD dwLowDateTime;
    DWORD dwHighDateTime;
} FILETIME, *LPFILETIME;

typedef struct _SYSTEMTIME {
    WORD wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
} SYSTEMTIME, *LPSYSTEMTIME;

// FILETIME is 100-ns intervals since 1601-01-01 UTC. Helpers to bridge time_t.
void     UnixTimeToFileTime(time_t t, FILETIME* ft);
time_t   FileTimeToUnixTime(const FILETIME* ft);
void     SystemTimeToFileTime_compat(const SYSTEMTIME* st, FILETIME* ft);

// Win32 time API (win_compat.cpp).
void     GetSystemTime(SYSTEMTIME* st);                          // UTC
void     GetLocalTime(SYSTEMTIME* st);                           // local
BOOL     SystemTimeToFileTime(const SYSTEMTIME* st, FILETIME* ft);
BOOL     FileTimeToSystemTime(const FILETIME* ft, SYSTEMTIME* st);
BOOL     FileTimeToLocalFileTime(const FILETIME* ft, FILETIME* local);

// UTF-8 <-> wchar_t (wchar_t is 32-bit on macOS; self-consistent round-trip).
int  MultiByteToWideChar(UINT cp, DWORD flags, LPCSTR src, int srcLen, wchar_t* dst, int dstLen);
int  WideCharToMultiByte(UINT cp, DWORD flags, const wchar_t* src, int srcLen, LPSTR dst, int dstLen,
                         LPCSTR defChar, BOOL* usedDefault);

// File + memory-mapping shims (HANDLE-based file I/O, mmap, temp paths, etc.).
#include "win_file.h"
// shlwapi Path* helpers + the thread shim.
#include "win_path.h"
#include "win_thread.h"

#endif // NPPFTP_WIN_COMPAT_H
