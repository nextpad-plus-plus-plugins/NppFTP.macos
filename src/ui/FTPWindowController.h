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
	void  ActionGlobalSettings();
	void  ActionMessagesToggle();
	void  OnTreeActivate(FileObject* fo);     // double-click on a remote item
	void  OnTreeExpand(FileObject* fo);       // lazy-load a remote directory

	// ── profile-tree actions (disconnected panel; context = SetContextProfile) ─
	void  SetContextProfile(FTPProfile* p) { m_contextProfile = p; }
	void  ActionCreateProfile();
	void  ActionConnectProfile(FTPProfile* p);
	void  ActionConnectContextProfile();
	void  ActionEditContextProfile();
	void  ActionRenameContextProfile();
	void  ActionDeleteContextProfile();
	void  ActionCopyContextProfile();

	// ── context-menu file operations (target = SetContextTarget) ────────────
	void  SetContextTarget(FileObject* fo) { m_selected = fo; }
	void  ActionRefreshDir();
	void  ActionUploadTo();
	void  ActionMkDir();
	void  ActionMkFile();
	void  ActionDownloadOpen();
	void  ActionDownloadTo();
	void  ActionRename();
	void  ActionDelete();
	void  ActionChmod();

	// accessors for the ObjC data sources
	FTPSession* Session()   { return m_session; }
	vProfile*   Profiles()  { return m_profiles; }
	FileObject* RootObject();
	void  AppendOutput(int type, const char* msg);   // append to the Messages view

	// transfer-queue model (one row per in-flight operation, Add→Remove)
	struct ActiveOp { QueueOperation* op; std::string action; std::string file; float progress; };
	size_t           QueueCount()        { return m_activeOps.size(); }
	const ActiveOp*  QueueAt(size_t i)   { return i < m_activeOps.size() ? &m_activeOps[i] : nullptr; }

private:
	void  RebuildTree();
	void  RefreshQueue();
	void  UpdateToolbarState();   // enable/disable connection-requiring buttons
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
	void*           m_toolbar;      // NSView* holding the toolbar buttons (tag 1 = needs connection)
	void*           m_panelHandle;  // host panel handle from NPPM_DMM_REGISTERPANEL
	FileObject*     m_selected;     // currently-selected remote object
	FTPProfile*     m_contextProfile;  // right-clicked profile (disconnected tree)
	bool            m_visible;
	std::vector<ActiveOp> m_activeOps;   // in-flight transfer queue
};

#endif // NPPFTP_FTPWINDOWCONTROLLER_H
