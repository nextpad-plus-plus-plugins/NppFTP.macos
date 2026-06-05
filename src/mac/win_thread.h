/*
 * win_thread.h — minimal Win32 thread shim for the NppFTP port.
 * NppFTP's FTPQueue spawns a single fire-and-forget worker thread; the handle
 * is discarded. We back CreateThread with a detached pthread.
 * NppFTP macOS port 2026 (GPL v3).
 */
#ifndef NPPFTP_WIN_THREAD_H
#define NPPFTP_WIN_THREAD_H

#include "win_compat.h"
#include <atomic>

#ifndef INFINITE
  #define INFINITE 0xFFFFFFFFu
#endif

typedef DWORD (*LPTHREAD_START_ROUTINE)(LPVOID);

namespace nppftp_detail {
    struct ThreadArg { LPTHREAD_START_ROUTINE fn; LPVOID param; };
    static inline void* thread_trampoline(void* a) {
        ThreadArg* ta = (ThreadArg*)a;
        LPTHREAD_START_ROUTINE fn = ta->fn; LPVOID p = ta->param;
        delete ta;
        fn(p);
        return NULL;
    }
}

static inline HANDLE CreateThread(LPSECURITY_ATTRIBUTES /*sa*/, SIZE_T /*stack*/,
                                  LPTHREAD_START_ROUTINE start, LPVOID param,
                                  DWORD /*flags*/, LPDWORD threadId) {
    pthread_t tid;
    nppftp_detail::ThreadArg* ta = new nppftp_detail::ThreadArg{start, param};
    if (pthread_create(&tid, NULL, nppftp_detail::thread_trampoline, ta) != 0) {
        delete ta;
        return NULL;
    }
    pthread_detach(tid);
    if (threadId) *threadId = (DWORD)(uintptr_t)tid;
    return (HANDLE)1;   // non-null sentinel; FTPQueue discards it
}

static inline DWORD GetCurrentThreadId(void) {
    return (DWORD)(uintptr_t)pthread_self();
}

// The notify HWND's owning thread — unused after the notify-callback rewrite;
// returns 0 (so "different thread" path is taken, which posts asynchronously).
static inline DWORD GetWindowThreadProcessId(HWND, LPDWORD pid) { if (pid) *pid = 0; return 0; }

// ── Timer-queue timer (used for the FTP keep-alive NoOp) ────────────────────
typedef void (*WAITORTIMERCALLBACK)(PVOID, BOOLEAN);
#ifndef WT_EXECUTEINTIMERTHREAD
  #define WT_EXECUTEDEFAULT       0x00000000
  #define WT_EXECUTEINTIMERTHREAD 0x00000020
  #define WT_EXECUTEONLYONCE      0x00000008
#endif

namespace nppftp_detail {
    struct TimerRec {
        WAITORTIMERCALLBACK cb;
        PVOID               param;
        DWORD               dueMs;
        DWORD               periodMs;
        std::atomic<bool>   stop{false};
        pthread_t           tid{};
    };
    static inline void* timer_thread(void* a) {
        TimerRec* t = (TimerRec*)a;
        // due time
        DWORD waited = 0;
        while (!t->stop && waited < t->dueMs) { ::usleep(10000); waited += 10; }
        while (!t->stop) {
            t->cb(t->param, TRUE);
            if (t->periodMs == 0) break;             // one-shot
            DWORD w = 0;
            while (!t->stop && w < t->periodMs) { ::usleep(10000); w += 10; }
        }
        return NULL;
    }
}

// CreateTimerQueueTimer(&handle, queue(ignored), cb, param, dueTime, period, flags).
static inline BOOL CreateTimerQueueTimer(HANDLE* phNewTimer, HANDLE /*queue*/,
                                         WAITORTIMERCALLBACK cb, PVOID param,
                                         DWORD dueTime, DWORD period, ULONG /*flags*/) {
    nppftp_detail::TimerRec* t = new nppftp_detail::TimerRec{cb, param, dueTime, period, {false}, {}};
    if (pthread_create(&t->tid, NULL, nppftp_detail::timer_thread, t) != 0) { delete t; return FALSE; }
    *phNewTimer = (HANDLE)t;
    return TRUE;
}
// DeleteTimerQueueTimer(queue(ignored), timer, completionEvent(ignored)) — stops + joins.
static inline BOOL DeleteTimerQueueTimer(HANDLE /*queue*/, HANDLE timer, HANDLE /*completion*/) {
    if (!timer) return FALSE;
    nppftp_detail::TimerRec* t = (nppftp_detail::TimerRec*)timer;
    t->stop = true;
    pthread_join(t->tid, NULL);
    delete t;
    return TRUE;
}

#endif // NPPFTP_WIN_THREAD_H
