/*
 * NppFTPPlugin.mm — macOS (Nextpad++) plugin entry + orchestrator for NppFTP.
 *
 * Provides the 5 required exports, the 3 menu commands (Show / Focus / About),
 * the engine's global externs (_MainOutput / _MainOutputWindow / _ConfigPath /
 * _HostsFile), and the Start/Stop wiring that creates the FTPSession +
 * FTPWindowController and loads the saved profiles/settings.
 *
 * NppFTP macOS port 2026 (GPL v3, as upstream).
 */
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include "StdInc.h"
#include "FTPWindowController.h"
#include "FTPSession.h"
#include "FTPSettings.h"
#include "FTPProfile.h"
#include "Encryption.h"
#include "SSLCertificates.h"
#include "Output.h"
#include "UIProvider.h"
#include <string>
#include <vector>

// ── engine globals (declared extern in the engine headers) ──────────────────
HWND    _MainOutputWindow = NULL;     // holds the Notifier* (the controller)
TCHAR*  _ConfigPath       = NULL;
char*   _HostsFile        = NULL;

// Output sink: routes engine messages to the controller's Messages view, with a
// stderr fallback before the UI exists.
class CocoaOutput : public Output {
public:
	FTPWindowController* controller = nullptr;
	int OutVA(Output_Type type, const TCHAR* message, va_list vaList) override {
		if (!message) return 0;                 // never crash the logger on a NULL format
		char buf[4096];
		std::string fmt(message);
		size_t pos = 0;
		while ((pos = fmt.find("%T", pos)) != std::string::npos) { fmt[pos + 1] = 's'; pos += 2; }
		vsnprintf(buf, sizeof(buf), fmt.c_str(), vaList);
		// The controller appends to the Messages window on the main thread.
		extern void NppFTP_AppendOutput(FTPWindowController*, int, const char*);
		if (controller) NppFTP_AppendOutput(controller, (int)type, buf);
		else            fprintf(stderr, "%s\n", buf);
		return 0;
	}
};
static CocoaOutput   g_output;
Output* _MainOutput = &g_output;

// ── plugin state ────────────────────────────────────────────────────────────
static const char* PLUGIN_NAME = "NppFTP";
static const int   NB_FUNC = 3;
static FuncItem    funcItem[NB_FUNC];
static NppData     nppData;

static FTPWindowController* g_controller = nullptr;
static FTPSession*          g_session    = nullptr;
static FTPSettings*         g_settings   = nullptr;
static vProfile             g_profiles;
static vX509                g_certificates;
static bool                 g_started    = false;
static std::string          g_configDir;    // ~/.nextpad++/plugins/Config/NppFTP

static std::string pluginsConfigDir() {
	char buf[2048]; buf[0] = '\0';
	nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, sizeof(buf), (intptr_t)buf);
	if (buf[0] != '\0') return std::string(buf);
	@autoreleasepool {
		NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@".nextpad++/plugins/Config"];
		return std::string([dir UTF8String]);
	}
}

// ── orchestrator ────────────────────────────────────────────────────────────
static int LoadSettings() {
	g_settings = new FTPSettings();
	// Profiles + settings XML live in <config>/NppFTP/NppFTP.xml. Load if present.
	std::string xmlPath = g_configDir + "/NppFTP.xml";
	TiXmlDocument doc(xmlPath.c_str());
	if (doc.LoadFile()) {
		const TiXmlElement* root = doc.RootElement();
		if (root) {
			const TiXmlElement* profilesElem = root->FirstChildElement("Profiles");
			if (profilesElem) g_profiles = FTPProfile::LoadProfiles(profilesElem);
			const TiXmlElement* settingsElem = root->FirstChildElement("Settings");
			if (settingsElem) g_settings->LoadSettings(settingsElem);
		}
	}
	return 0;
}

// Persist profiles + settings back to <config>/NppFTP/NppFTP.xml (mirror of LoadSettings).
extern "C" void NppFTP_SaveSettings() {
	if (!g_settings) return;
	std::string xmlPath = g_configDir + "/NppFTP.xml";
	TiXmlDocument doc(xmlPath.c_str());
	TiXmlDeclaration decl("1.0", "UTF-8", "");
	doc.InsertEndChild(decl);
	TiXmlElement root("NppFTP");
	TiXmlElement* profilesElem = FTPProfile::SaveProfiles(g_profiles);
	if (profilesElem) { root.LinkEndChild(profilesElem); }
	TiXmlElement settingsElem("Settings");
	g_settings->SaveSettings(&settingsElem);
	root.LinkEndChild(new TiXmlElement(settingsElem));
	doc.InsertEndChild(root);
	doc.SaveFile();
}

// Accessors for the dialogs (invoked from the controller).
extern "C" vProfile*    NppFTP_Profiles()  { return &g_profiles; }
extern "C" FTPSettings* NppFTP_Settings()  { return g_settings; }

static int StartNppFTP() {
	if (g_started) return 0;

	Encryption::Init();

	g_configDir = pluginsConfigDir() + "/NppFTP";
	@autoreleasepool {
		[[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:g_configDir.c_str()]
		                          withIntermediateDirectories:YES attributes:nil error:nil];
	}
	_ConfigPath = strdup((g_configDir + "/").c_str());
	_HostsFile  = strdup((g_configDir + "/known_hosts").c_str());

	LoadSettings();

	g_controller = new FTPWindowController(&nppData);
	g_session    = new FTPSession();
	g_output.controller = g_controller;

	if (g_controller->Create((void*)nppData._nppHandle, (void*)nppData._nppHandle, 0, funcItem[0]._cmdID) == -1)
		return -1;
	if (g_session->Init(g_controller, g_settings) == -1) { g_controller->Destroy(); return -1; }
	if (g_controller->Init(g_session, &g_profiles, g_settings) == -1) { g_controller->Destroy(); return -1; }
	g_session->SetCertificates(&g_certificates);

	g_started = true;
	OutDebug("[NppFTP] Everything initialized");
	return 0;
}

// ── menu commands ────────────────────────────────────────────────────────────
extern "C" void cmdAbout();  // defined in FTPWindowController.mm (About box)
static void cmdShowWindow()  { if (g_started && g_controller) g_controller->Show(!g_controller->IsVisible()); }
static void cmdFocusWindow() { if (g_started && g_controller) { g_controller->Show(true); g_controller->Focus(); } }

// ── exports ──────────────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
	nppData = data;
	_MainOutputWindow = (HWND)nppData._nppHandle;

	strlcpy(funcItem[0]._itemName, "Show NppFTP Window", NPP_MENU_ITEM_SIZE);
	funcItem[0]._pFunc = cmdShowWindow; funcItem[0]._init2Check = false; funcItem[0]._pShKey = nullptr;
	strlcpy(funcItem[1]._itemName, "Focus NppFTP Window", NPP_MENU_ITEM_SIZE);
	funcItem[1]._pFunc = cmdFocusWindow; funcItem[1]._init2Check = false; funcItem[1]._pShKey = nullptr;
	strlcpy(funcItem[2]._itemName, "About NppFTP", NPP_MENU_ITEM_SIZE);
	funcItem[2]._pFunc = cmdAbout; funcItem[2]._init2Check = false; funcItem[2]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char* getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem* getFuncsArray(int* nbF) { *nbF = NB_FUNC; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification* n) {
	if (!n) return;
	switch (n->nmhdr.code) {
		case NPPN_READY:
			StartNppFTP();
			break;
		case NPPN_FILESAVED: {
			if (!g_started) break;
			// Upload-on-save: resolve the saved buffer's path and offer to upload
			// if it lives in the cache. (Wired in the controller.)
			char path[2048]; path[0] = 0;
			nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLPATHFROMBUFFERID, (uintptr_t)n->nmhdr.idFrom, (intptr_t)path);
			if (path[0] && g_controller) g_controller->OnActivateLocalFile(path);
			break;
		}
		case NPPN_SHUTDOWN:
			break;
		default: break;
	}
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }

// host accessor used by the controller
extern "C" NppData* NppFTP_HostData() { return &nppData; }
