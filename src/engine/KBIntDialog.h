/* KBIntDialog.h — macOS port: keyboard-interactive auth over UIProvider. */
#ifndef NPPFTP_KBINTDIALOG_H
#define NPPFTP_KBINTDIALOG_H
#include "UIProvider.h"
#include <libssh/libssh.h>
class KBIntDialog {
public:
	KBIntDialog() {}
	virtual ~KBIntDialog() {}
	// Returns 1 (answered), 0 (no input required), -1 (error), 2 (cancelled).
	virtual int Create(void* hParent, ssh_session session) {
		if (!g_uiProvider) return -1;
		return g_uiProvider->PromptKBInt(hParent, session);
	}
};
#endif
