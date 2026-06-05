/* Prompts.cpp — the active UI provider (set by the Cocoa UI or the test harness). */
#include "UIProvider.h"
UIProvider* g_uiProvider = nullptr;
void SetUIProvider(UIProvider* provider) { g_uiProvider = provider; }

#include "win_compat.h"   // MB_*/ID* constants
int MessageBox(void* parent, const char* text, const char* caption, unsigned flags) {
    if (!g_uiProvider) return (flags & 0x04 /*MB_YESNO*/) ? 7 /*IDNO*/ : 2 /*IDCANCEL*/;
    return g_uiProvider->MessageBox(parent, text, caption, flags);
}
