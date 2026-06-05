/* MessageDialog.h — macOS port: informational/confirm message (thin). */
#ifndef NPPFTP_MESSAGEDIALOG_H
#define NPPFTP_MESSAGEDIALOG_H
#include "UIProvider.h"
class MessageDialog {
public:
	MessageDialog() {}
	virtual ~MessageDialog() {}
	virtual int Create(void* /*hParent*/, const char* /*title*/, const char* /*message*/) { return 0; }
};
#endif
