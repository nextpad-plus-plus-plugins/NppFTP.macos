/*
 * FTPWindowController.mm — Cocoa dock panel for the NppFTP macOS port.
 * NppFTP macOS port 2026 (GPL v3).
 */
#import <Cocoa/Cocoa.h>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#include "FTPWindowController.h"
#include "FileObject.h"
#include "PathUtils.h"
#include "Output.h"

extern "C" NppData* NppFTP_HostData();
static intptr_t hostMsg(uint32_t msg, uintptr_t w, intptr_t l) {
	NppData* d = NppFTP_HostData();
	return d->_sendMessage(d->_nppHandle, msg, w, l);
}

// ───────────────────────────── ObjC bridge ─────────────────────────────────
// Data source/delegate for the remote tree + queue, and toolbar action target.
@interface NppFTPBridge : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource>
@property (assign, nonatomic) FTPWindowController* ctrl;
@end

@implementation NppFTPBridge

// The outline shows the connected remote tree (root = session RootObject); when
// disconnected it shows the profile list.
- (id)rootObject { return [NSValue valueWithPointer:self.ctrl->RootObject()]; }

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item {
	FileObject* fo = item ? (FileObject*)[(NSValue*)item pointerValue] : self.ctrl->RootObject();
	return fo ? fo->GetChildCount() : (NSInteger)self.ctrl->Profiles()->size();
}
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item {
	FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
	return fo && fo->isDir();
}
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)index ofItem:(id)item {
	FileObject* parent = item ? (FileObject*)[(NSValue*)item pointerValue] : self.ctrl->RootObject();
	if (!parent) {  // disconnected → profiles shown as leaf rows (wrapped index)
		return [NSValue valueWithPointer:(void*)(intptr_t)(index + 1)];
	}
	return [NSValue valueWithPointer:parent->GetChild((int)index)];
}
- (id)outlineView:(NSOutlineView*)ov objectValueForTableColumn:(NSTableColumn*)col byItem:(id)item {
	FileObject* root = self.ctrl->RootObject();
	if (!root) {  // profile list
		intptr_t idx = (intptr_t)[(NSValue*)item pointerValue] - 1;
		if (idx >= 0 && (size_t)idx < self.ctrl->Profiles()->size())
			return [NSString stringWithUTF8String:self.ctrl->Profiles()->at(idx)->GetName()];
		return @"";
	}
	FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
	return fo ? [NSString stringWithUTF8String:fo->GetName()] : @"";
}
- (void)outlineViewItemWillExpand:(NSNotification*)n {
	id item = n.userInfo[@"NSObject"];
	FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
	if (fo) self.ctrl->OnTreeExpand(fo);
}
- (void)onOutlineDoubleClick:(NSOutlineView*)ov {
	NSInteger row = ov.clickedRow;
	if (row < 0) return;
	id item = [ov itemAtRow:row];
	FileObject* root = self.ctrl->RootObject();
	if (!root) { self.ctrl->ActionConnectSelected(); return; }
	FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
	if (fo) self.ctrl->OnTreeActivate(fo);
}

// toolbar actions
- (void)tbConnect:(id)s    { self.ctrl->ActionConnectSelected(); }
- (void)tbDisconnect:(id)s { self.ctrl->ActionDisconnect(); }
- (void)tbDownload:(id)s   { self.ctrl->ActionDownloadSelected(); }
- (void)tbUpload:(id)s     { self.ctrl->ActionUploadCurrent(); }
- (void)tbRefresh:(id)s    { self.ctrl->ActionRefresh(); }
- (void)tbAbort:(id)s      { self.ctrl->ActionAbort(); }
- (void)tbSettings:(id)s   { self.ctrl->ActionGlobalSettings(); }
- (void)tbMessages:(id)s   { self.ctrl->ActionMessagesToggle(); }

// queue table (one row per active operation — minimal columns)
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return 0; }
- (id)tableView:(NSTableView*)t objectValueForTableColumn:(NSTableColumn*)c row:(NSInteger)r { return @""; }
@end

// ─────────────────────────── controller impl ───────────────────────────────
FTPWindowController::FTPWindowController(const NppData* npp)
	: m_npp(npp), m_session(nullptr), m_profiles(nullptr), m_settings(nullptr),
	  m_panelView(nullptr), m_outline(nullptr), m_queueTable(nullptr),
	  m_outputView(nullptr), m_bridge(nullptr), m_panelHandle(nullptr),
	  m_selected(nullptr), m_visible(false) {}

FTPWindowController::~FTPWindowController() {}

FileObject* FTPWindowController::RootObject() {
	return (m_session && m_session->IsConnected()) ? m_session->GetRootObject() : nullptr;
}

int FTPWindowController::Create(void*, void*, int, int) {
	@autoreleasepool {
		NSView* panel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];
		NppFTPBridge* bridge = [[NppFTPBridge alloc] init];
		bridge.ctrl = this;
		m_bridge = (void*)CFBridgingRetain(bridge);

		// toolbar row
		NSView* tb = [[NSView alloc] initWithFrame:NSMakeRect(0, 572, 320, 28)];
		tb.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
		struct { const char* t; SEL a; } btns[] = {
			{"Connect", @selector(tbConnect:)}, {"Disconnect", @selector(tbDisconnect:)},
			{"Download", @selector(tbDownload:)}, {"Upload", @selector(tbUpload:)},
			{"Refresh", @selector(tbRefresh:)}, {"Abort", @selector(tbAbort:)},
			{"Settings", @selector(tbSettings:)}, {"Messages", @selector(tbMessages:)},
		};
		CGFloat x = 4;
		for (auto& b : btns) {
			NSButton* btn = [NSButton buttonWithTitle:[NSString stringWithUTF8String:b.t] target:bridge action:b.a];
			btn.bezelStyle = NSBezelStyleRecessed; btn.frame = NSMakeRect(x, 2, 36, 24);
			btn.font = [NSFont systemFontOfSize:9];
			[tb addSubview:btn]; x += 38;
		}
		[panel addSubview:tb];

		// remote tree
		NSScrollView* treeScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 220, 320, 350)];
		treeScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		treeScroll.hasVerticalScroller = YES; treeScroll.borderType = NSBezelBorder;
		NSOutlineView* outline = [[NSOutlineView alloc] initWithFrame:treeScroll.bounds];
		NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
		col.title = @"Remote";
		[outline addTableColumn:col]; outline.outlineTableColumn = col;
		outline.dataSource = bridge; outline.delegate = bridge;
		outline.headerView = nil;
		outline.target = bridge; outline.doubleAction = @selector(onOutlineDoubleClick:);
		treeScroll.documentView = outline;
		[panel addSubview:treeScroll];
		m_outline = (void*)CFBridgingRetain(outline);

		// transfer queue
		NSScrollView* qScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 110, 320, 108)];
		qScroll.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
		qScroll.hasVerticalScroller = YES; qScroll.borderType = NSBezelBorder;
		NSTableView* qtable = [[NSTableView alloc] initWithFrame:qScroll.bounds];
		for (NSString* c in @[@"Action", @"Progress", @"File"]) {
			NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:c]; tc.title = c;
			[qtable addTableColumn:tc];
		}
		qtable.dataSource = bridge;
		qScroll.documentView = qtable;
		[panel addSubview:qScroll];
		m_queueTable = (void*)CFBridgingRetain(qtable);

		// messages (hidden by default; toggled by the Messages button)
		NSScrollView* oScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 320, 108)];
		oScroll.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
		oScroll.hasVerticalScroller = YES; oScroll.borderType = NSBezelBorder;
		NSTextView* tv = [[NSTextView alloc] initWithFrame:oScroll.bounds];
		tv.editable = NO; tv.font = [NSFont fontWithName:@"Menlo" size:10] ?: [NSFont systemFontOfSize:10];
		oScroll.documentView = tv;
		[panel addSubview:oScroll];
		m_outputView = (void*)CFBridgingRetain(tv);

		m_panelView = (void*)CFBridgingRetain(panel);

		// Register as a docked panel (host strong-retains the view).
		m_panelHandle = (void*)hostMsg(NPPM_DMM_REGISTERPANEL, (uintptr_t)panel, (intptr_t)"NppFTP");
	}
	return 0;
}

int FTPWindowController::Init(FTPSession* session, vProfile* vProfiles, FTPSettings* ftpSettings) {
	m_session = session; m_profiles = vProfiles; m_settings = ftpSettings;
	RebuildTree();
	return 0;
}

int FTPWindowController::Destroy() {
	if (m_panelHandle) hostMsg(NPPM_DMM_UNREGISTERPANEL, (uintptr_t)m_panelHandle, 0);
	return 0;
}

int FTPWindowController::Show(bool show) {
	m_visible = show;
	if (m_panelHandle)
		hostMsg(show ? NPPM_DMM_SHOWPANEL : NPPM_DMM_HIDEPANEL, (uintptr_t)m_panelHandle, 0);
	return 0;
}
int FTPWindowController::Focus() {
	@autoreleasepool {
		NSView* v = (__bridge NSView*)m_panelView;
		[v.window makeFirstResponder:v];
	}
	return 0;
}
bool FTPWindowController::IsVisible() { return m_visible; }
void* FTPWindowController::GetHWND() { return (void*)(Notifier*)this; }

int FTPWindowController::OnActivateLocalFile(const char*) { return 0; }

void FTPWindowController::RebuildTree() {
	@autoreleasepool { if (m_outline) [(__bridge NSOutlineView*)m_outline reloadData]; }
}

void FTPWindowController::AppendOutput(int /*type*/, const char* msg) {
	@autoreleasepool {
		NSTextView* tv = (__bridge NSTextView*)m_outputView;
		if (!tv) return;
		NSString* line = [NSString stringWithFormat:@"%s\n", msg ? msg : ""];
		[tv.textStorage.mutableString appendString:line];
		[tv scrollRangeToVisible:NSMakeRange(tv.string.length, 0)];
	}
}

// ── Notifier ────────────────────────────────────────────────────────────────
bool FTPWindowController::IsUIThread() { return [NSThread isMainThread]; }

void FTPWindowController::Notify(int message, int code, QueueOperation* op) {
	if (IsUIThread()) { HandleNotification(message, code, op); return; }
	FTPWindowController* self = this;
	dispatch_async(dispatch_get_main_queue(), ^{
		self->HandleNotification(message, code, op);
		op->AckNotification();
	});
}
void FTPWindowController::ClearPending(QueueOperation*) {}

void FTPWindowController::HandleNotification(int /*message*/, int /*code*/, QueueOperation* /*op*/) {
	// Refresh the tree on any queue event; specific handling (open downloaded
	// file via NPPM_DOOPEN) is wired with the operation result types next.
	RebuildTree();
}

// ── UIProvider ──────────────────────────────────────────────────────────────
int FTPWindowController::PromptInput(void*, const char* title, const char* comment,
                                     const char* initialValue, bool password, std::string& out) {
	__block int result = 2;
	void (^show)(void) = ^{
		@autoreleasepool {
			NSAlert* a = [[NSAlert alloc] init];
			a.messageText = [NSString stringWithUTF8String:title ? title : "NppFTP"];
			a.informativeText = [NSString stringWithUTF8String:comment ? comment : ""];
			NSTextField* field = password
				? (NSTextField*)[[NSSecureTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)]
				: [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
			field.stringValue = [NSString stringWithUTF8String:initialValue ? initialValue : ""];
			a.accessoryView = field;
			[a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
			if ([a runModal] == NSAlertFirstButtonReturn) { out = field.stringValue.UTF8String; result = 1; }
		}
	};
	if ([NSThread isMainThread]) show(); else dispatch_sync(dispatch_get_main_queue(), show);
	return result;
}

int FTPWindowController::PromptKBInt(void*, ssh_session session) {
	// Read libssh prompts, ask the user, set the answers.
	int n = ssh_userauth_kbdint_getnprompts(session);
	if (n == 0) return 0;
	for (int i = 0; i < n; i++) {
		char echo = 0;
		const char* prompt = ssh_userauth_kbdint_getprompt(session, i, &echo);
		std::string ans;
		int r = PromptInput(nullptr, "Keyboard-interactive", prompt ? prompt : "", "", echo == 0, ans);
		if (r != 1) return 2;
		ssh_userauth_kbdint_setanswer(session, i, ans.c_str());
	}
	return 1;
}

int FTPWindowController::MessageBox(void*, const char* text, const char* caption, unsigned flags) {
	__block int result = (flags & MB_YESNO) ? IDNO : IDCANCEL;
	void (^show)(void) = ^{
		@autoreleasepool {
			NSAlert* a = [[NSAlert alloc] init];
			a.messageText = [NSString stringWithUTF8String:caption ? caption : "NppFTP"];
			a.informativeText = [NSString stringWithUTF8String:text ? text : ""];
			if (flags & MB_YESNO) { [a addButtonWithTitle:@"Yes"]; [a addButtonWithTitle:@"No"]; }
			else                  { [a addButtonWithTitle:@"OK"]; }
			NSModalResponse resp = [a runModal];
			if (flags & MB_YESNO) result = (resp == NSAlertFirstButtonReturn) ? IDYES : IDNO;
			else                  result = IDOK;
		}
	};
	if ([NSThread isMainThread]) show(); else dispatch_sync(dispatch_get_main_queue(), show);
	return result;
}

// ── actions ──────────────────────────────────────────────────────────────────
void FTPWindowController::ActionConnectSelected() {
	if (!m_session || m_profiles->empty()) return;
	@autoreleasepool {
		NSOutlineView* ov = (__bridge NSOutlineView*)m_outline;
		NSInteger row = ov.selectedRow >= 0 ? ov.selectedRow : 0;
		if ((size_t)row >= m_profiles->size()) row = 0;
		m_session->StartSession(m_profiles->at(row));
		m_session->Connect();
	}
}
void FTPWindowController::ActionDisconnect() { if (m_session) m_session->TerminateSession(); RebuildTree(); }
void FTPWindowController::ActionRefresh() {
	if (m_session && m_session->IsConnected()) m_session->GetDirectory("/");
}
void FTPWindowController::ActionAbort() {}
void FTPWindowController::ActionDownloadSelected() { if (m_selected) OnTreeActivate(m_selected); }
void FTPWindowController::ActionUploadCurrent() {
	char path[2048]; path[0] = 0;
	hostMsg(NPPM_GETFULLCURRENTPATH, sizeof(path), (intptr_t)path);
	// Upload-on-demand wiring (cache mapping) is completed with the dialogs.
}
void FTPWindowController::ActionGlobalSettings() {}   // Global settings dialog (next)
void FTPWindowController::ActionMessagesToggle() {}

void FTPWindowController::OnTreeExpand(FileObject* fo) {
	if (m_session && m_session->IsConnected() && fo && fo->isDir())
		m_session->GetDirectory(fo->GetPath());
}

void FTPWindowController::OnTreeActivate(FileObject* fo) {
	if (!fo) return;
	m_selected = fo;
	if (fo->isDir()) { if (m_session) m_session->GetDirectory(fo->GetPath()); return; }
	// download the file; when complete, HandleNotification opens it via NPPM_DOOPEN
	if (m_session) m_session->DownloadFile(fo->GetPath(), _ConfigPath, true);
}

// ── globals referenced by the plugin entry ───────────────────────────────────
void NppFTP_AppendOutput(FTPWindowController* c, int type, const char* msg) {
	if (!c) return;
	if ([NSThread isMainThread]) {
		c->AppendOutput(type, msg);
	} else {
		std::string m = msg ? msg : "";
		dispatch_async(dispatch_get_main_queue(), ^{ c->AppendOutput(type, m.c_str()); });
	}
}

extern "C" void cmdAbout() {
	@autoreleasepool {
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"NppFTP";
		a.informativeText = @"FTP/FTPS/SFTP client for Nextpad++.\n\nmacOS port of NppFTP (Harry / ashkulz).\nGPL v3.";
		[a addButtonWithTitle:@"OK"];
		[a runModal];
	}
}
