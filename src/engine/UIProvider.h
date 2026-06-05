/*
 * UIProvider.h — engine→UI prompt boundary for the NppFTP macOS port.
 *
 * The engine (FTPProfile, FTPClientWrapperSSH) needs to prompt the user for
 * passwords / passphrases / keyboard-interactive answers. On Windows these were
 * Win32 dialogs included directly. Here the engine calls an abstract provider;
 * the Cocoa layer registers a real implementation, and the headless test
 * harness registers a non-interactive stub.
 *
 * NppFTP macOS port 2026 (GPL v3).
 */
#ifndef NPPFTP_UIPROVIDER_H
#define NPPFTP_UIPROVIDER_H

#include <string>
#include <libssh/libssh.h>

class UIProvider {
public:
	virtual ~UIProvider() {}

	// Single text prompt. Returns 1 if the user entered a value (placed in out),
	// 2 if cancelled / no input.
	virtual int PromptInput(void* parent, const char* title, const char* comment,
	                        const char* initialValue, bool password, std::string& out) = 0;

	// libssh keyboard-interactive challenge round. The implementation reads the
	// prompts from the session, asks the user, and sets the answers via
	// ssh_userauth_kbdint_setanswer. Returns 1 (answered), 0 (no prompts),
	// -1 (error), 2 (cancelled).
	virtual int PromptKBInt(void* parent, ssh_session session) = 0;

	// Message/confirmation box. flags use the MB_* constants; returns an ID*
	// code (IDOK/IDYES/IDNO/IDCANCEL).
	virtual int MessageBox(void* parent, const char* text, const char* caption, unsigned flags) = 0;
};

// Free function the engine calls as MessageBox(...) / ::MessageBox(...). Routes
// to the active provider (returns IDNO/IDCANCEL when none — the safe default).
int MessageBox(void* parent, const char* text, const char* caption, unsigned flags);

// The active provider (set by the Cocoa UI or the test harness). May be null,
// in which case prompts behave as "cancelled".
extern UIProvider* g_uiProvider;
void SetUIProvider(UIProvider* provider);

#endif // NPPFTP_UIPROVIDER_H
