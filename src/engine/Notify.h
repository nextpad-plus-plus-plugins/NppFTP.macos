/*
 * Notify.h — engine→UI result notifier for the NppFTP macOS port.
 * Replaces the Win32 PostMessage(hwnd, ...) flow: the worker thread posts a
 * completed/updated QueueOperation to the UI, which marshals to the main thread
 * and acks. The Cocoa FTP window implements this; a test stub may too.
 */
#ifndef NPPFTP_NOTIFY_H
#define NPPFTP_NOTIFY_H

class QueueOperation;

class Notifier {
public:
	virtual ~Notifier() {}
	// True when called on the UI (main) thread — then notifications are handled
	// synchronously (no ack/wait, to avoid self-deadlock).
	virtual bool IsUIThread() = 0;
	// Deliver a notification (message code + per-op code). When called off the
	// UI thread the implementation must, on the UI thread, handle it and then
	// call op->AckNotification().
	virtual void Notify(int message, int code, QueueOperation* op) = 0;
	// Drop any pending (not-yet-delivered) notifications for op.
	virtual void ClearPending(QueueOperation* op) = 0;
};

#endif // NPPFTP_NOTIFY_H
