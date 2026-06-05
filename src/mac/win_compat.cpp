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
