/*
 * FTPWindowController.h — the Cocoa dock-panel controller for the NppFTP macOS
 * port. A C++ class that implements the three engine interfaces (FTPWindow,
 * Notifier, UIProvider) and owns the Cocoa views (NSOutlineView tree +
 * NSTableView queue + toolbar) through ObjC++ in the .mm. Registered with the
 * host as a docked panel via NPPM_DMM_REGISTERPANEL.
 *
 * NppFTP macOS port 2026 (GPL v3).
 */
#ifndef NPPFTP_FTPWINDOWCONTROLLER_H
#define NPPFTP_FTPWINDOWCONTROLLER_H

#include "StdInc.h"
#include "FTPWindow.h"
#include "Notify.h"
#include "UIProvider.h"
#include "FTPSession.h"
#include "FTPProfile.h"
#include "FTPSettings.h"
#include "QueueOperation.h"

// Forward-declared host accessor (provided by the plugin entry).
struct NppData;

class FTPWindowController : public FTPWindow, public Notifier, public UIProvider {
public:
	FTPWindowController(const NppData* npp);
	virtual ~FTPWindowController();

	// ── FTPWindow ───────────────────────────────────────────────────────────
	int   Create(void* hParent, void* hNpp, int MenuID, int MenuCommand) override;
	int   Destroy() override;
	int   Init(FTPSession* session, vProfile* vProfiles, FTPSettings* ftpSettings) override;
	int   Show(bool show) override;
	int   Focus() override;
	bool  IsVisible() override;
	void* GetHWND() override;                 // returns (Notifier*)this
	int   OnActivateLocalFile(const char* filename) override;

	// ── Notifier (queue results from the worker thread) ─────────────────────
	bool  IsUIThread() override;
	void  Notify(int message, int code, QueueOperation* op) override;
	void  ClearPending(QueueOperation* op) override;

	// ── UIProvider (engine prompts) ─────────────────────────────────────────
	int   PromptInput(void* parent, const char* title, const char* comment,
	                  const char* initialValue, bool password, std::string& out) override;
	int   PromptKBInt(void* parent, ssh_session session) override;
	int   MessageBox(void* parent, const char* text, const char* caption, unsigned flags) override;

	// ── invoked on the main thread to process a delivered notification ──────
	void  HandleNotification(int message, int code, QueueOperation* op);

	// ── toolbar / tree actions (called from the ObjC bridge) ────────────────
	void  ActionConnectSelected();
	void  ActionDisconnect();
	void  ActionRefresh();
	void  ActionAbort();
	void  ActionDownloadSelected();
	void  ActionUploadCurrent();
	void  ActionProfileSettings();
	void  ActionGlobalSettings();
	void  ActionMessagesToggle();
	void  OnTreeActivate(FileObject* fo);     // double-click on a remote item
	void  OnTreeExpand(FileObject* fo);       // lazy-load a remote directory

	// accessors for the ObjC data sources
	FTPSession* Session()   { return m_session; }
	vProfile*   Profiles()  { return m_profiles; }
	FileObject* RootObject();
	void  AppendOutput(int type, const char* msg);   // append to the Messages view

private:
	void  RebuildTree();
	void  RefreshQueue();
	// engine-event handlers (ported from FTPWindow::OnConnect/OnDisconnect/OnDirectoryRefresh)
	void  OnConnect(int code);
	void  OnDisconnect();
	void  OnDirectoryRefresh(FileObject* parent, FTPFile* files, int count);

	const NppData*  m_npp;
	FTPSession*     m_session;
	vProfile*       m_profiles;
	FTPSettings*    m_settings;

	void*           m_panelView;    // NSView* (the dock content)
	void*           m_outline;      // NSOutlineView* (remote tree)
	void*           m_queueTable;   // NSTableView* (transfer queue)
	void*           m_outputView;   // NSTextView* (messages)
	void*           m_bridge;       // ObjC data-source/delegate bridge
	void*           m_panelHandle;  // host panel handle from NPPM_DMM_REGISTERPANEL
	FileObject*     m_selected;     // currently-selected remote object
	bool            m_visible;
};

#endif // NPPFTP_FTPWINDOWCONTROLLER_H
