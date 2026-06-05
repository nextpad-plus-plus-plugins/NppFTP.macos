/* InputDialog.h — macOS port: thin password/value prompt over UIProvider. */
#ifndef NPPFTP_INPUTDIALOG_H
#define NPPFTP_INPUTDIALOG_H
#include "UIProvider.h"
#include <string>
class InputDialog {
public:
	InputDialog() {}
	virtual ~InputDialog() {}
	// Returns 1 on input, 2 on no input (matches upstream).
	virtual int Create(void* hParent, const char* title, const char* comment,
	                   const char* initialValue, bool password = false) {
		if (!g_uiProvider) return 2;
		return g_uiProvider->PromptInput(hParent, title, comment, initialValue, password, m_value);
	}
	virtual const char* GetValue() { return m_value.c_str(); }
protected:
	std::string m_value;
};
#endif
