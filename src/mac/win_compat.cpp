/*
 * win_compat.cpp — out-of-line helpers for the Win32→POSIX shim.
 * NppFTP macOS port 2026 (GPL v3).
 */
#include "win_compat.h"
#include <mach/mach_time.h>

// FILETIME epoch (1601-01-01) to Unix epoch (1970-01-01), in seconds.
static const int64_t kFtUnixDeltaSec = 11644473600LL;
static const int64_t kFt100nsPerSec  = 10000000LL;

DWORD GetTickCount(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t ns = mach_absolute_time() * tb.numer / tb.denom;
    return (DWORD)(ns / 1000000ULL);   // milliseconds (wraps like Win32)
}

void UnixTimeToFileTime(time_t t, FILETIME* ft) {
    if (!ft) return;
    int64_t ll = ((int64_t)t + kFtUnixDeltaSec) * kFt100nsPerSec;
    ft->dwLowDateTime  = (DWORD)(ll & 0xFFFFFFFF);
    ft->dwHighDateTime = (DWORD)(ll >> 32);
}

time_t FileTimeToUnixTime(const FILETIME* ft) {
    if (!ft) return 0;
    int64_t ll = ((int64_t)ft->dwHighDateTime << 32) | (uint32_t)ft->dwLowDateTime;
    return (time_t)(ll / kFt100nsPerSec - kFtUnixDeltaSec);
}

void SystemTimeToFileTime_compat(const SYSTEMTIME* st, FILETIME* ft) {
    if (!st || !ft) return;
    struct tm tmv{};
    tmv.tm_year = st->wYear - 1900;
    tmv.tm_mon  = st->wMonth - 1;
    tmv.tm_mday = st->wDay;
    tmv.tm_hour = st->wHour;
    tmv.tm_min  = st->wMinute;
    tmv.tm_sec  = st->wSecond;
    tmv.tm_isdst = -1;
    time_t t = timegm(&tmv);   // SYSTEMTIME here is treated as UTC
    UnixTimeToFileTime(t, ft);
}

static void tmToSystemTime(const struct tm& tmv, SYSTEMTIME* st) {
    st->wYear = (WORD)(tmv.tm_year + 1900);
    st->wMonth = (WORD)(tmv.tm_mon + 1);
    st->wDayOfWeek = (WORD)tmv.tm_wday;
    st->wDay = (WORD)tmv.tm_mday;
    st->wHour = (WORD)tmv.tm_hour;
    st->wMinute = (WORD)tmv.tm_min;
    st->wSecond = (WORD)tmv.tm_sec;
    st->wMilliseconds = 0;
}

void GetSystemTime(SYSTEMTIME* st) {
    if (!st) return;
    time_t t = ::time(NULL);
    struct tm tmv; gmtime_r(&t, &tmv);
    tmToSystemTime(tmv, st);
}

void GetLocalTime(SYSTEMTIME* st) {
    if (!st) return;
    time_t t = ::time(NULL);
    struct tm tmv; localtime_r(&t, &tmv);
    tmToSystemTime(tmv, st);
}

BOOL SystemTimeToFileTime(const SYSTEMTIME* st, FILETIME* ft) {
    if (!st || !ft) return FALSE;
    SystemTimeToFileTime_compat(st, ft);
    return TRUE;
}

BOOL FileTimeToSystemTime(const FILETIME* ft, SYSTEMTIME* st) {
    if (!ft || !st) return FALSE;
    time_t t = FileTimeToUnixTime(ft);
    struct tm tmv; gmtime_r(&t, &tmv);
    tmToSystemTime(tmv, st);
    return TRUE;
}

BOOL FileTimeToLocalFileTime(const FILETIME* ft, FILETIME* local) {
    if (!ft || !local) return FALSE;
    time_t t = FileTimeToUnixTime(ft);
    struct tm tmv; localtime_r(&t, &tmv);
    // Express the local broken-down time back as a FILETIME (offset applied).
    long off = tmv.tm_gmtoff;
    UnixTimeToFileTime(t + off, local);
    return TRUE;
}

// ── UTF-8 <-> wchar_t (UCS-4 on macOS) ──────────────────────────────────────
static int utf8_decode(const char* s, int len, char32_t* out) {
    unsigned char c = (unsigned char)s[0];
    if (c < 0x80) { *out = c; return 1; }
    int n; char32_t cp;
    if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; }
    else { *out = 0xFFFD; return 1; }
    if (n > len) { *out = 0xFFFD; return 1; }
    for (int i = 1; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) { *out = 0xFFFD; return 1; }
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    *out = cp;
    return n;
}

static int utf8_encode(char32_t cp, char* out) {
    if (cp < 0x80) { out[0] = (char)cp; return 1; }
    if (cp < 0x800) { out[0] = (char)(0xC0 | (cp >> 6)); out[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
    if (cp < 0x10000) { out[0] = (char)(0xE0 | (cp >> 12)); out[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); out[2] = (char)(0x80 | (cp & 0x3F)); return 3; }
    out[0] = (char)(0xF0 | (cp >> 18)); out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); out[3] = (char)(0x80 | (cp & 0x3F)); return 4;
}

int MultiByteToWideChar(UINT, DWORD, LPCSTR src, int srcLen, wchar_t* dst, int dstLen) {
    int sl = (srcLen < 0) ? (int)strlen(src) + 1 : srcLen;  // include NUL if -1
    int produced = 0;
    int i = 0;
    while (i < sl) {
        char32_t cp;
        int adv = utf8_decode(src + i, sl - i, &cp);
        i += adv;
        if (dstLen == 0) { produced++; continue; }
        if (produced >= dstLen) return 0;  // buffer too small
        dst[produced++] = (wchar_t)cp;
    }
    return produced;
}

int WideCharToMultiByte(UINT, DWORD, const wchar_t* src, int srcLen, LPSTR dst, int dstLen,
                        LPCSTR, BOOL* usedDefault) {
    if (usedDefault) *usedDefault = FALSE;
    int sl = (srcLen < 0) ? (int)wcslen(src) + 1 : srcLen;
    int produced = 0;
    for (int i = 0; i < sl; i++) {
        char buf[4];
        int n = utf8_encode((char32_t)src[i], buf);
        if (dstLen == 0) { produced += n; continue; }
        if (produced + n > dstLen) return 0;
        for (int k = 0; k < n; k++) dst[produced++] = buf[k];
    }
    return produced;
}
