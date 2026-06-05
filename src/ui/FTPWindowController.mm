/*
 * FTPWindowController.mm — Cocoa dock panel for the NppFTP macOS port.
 * NppFTP macOS port 2026 (GPL v3).
 */
#import <Cocoa/Cocoa.h>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#include "FTPWindowController.h"
#include "FileObject.h"
#include "FTPFile.h"
#include "PathUtils.h"
#include "Output.h"
#include <zlib.h>
#include <libssh/libssh.h>
#include <openssl/opensslv.h>

// Tiny target for the About box's buttons (Close / Visit site).
@interface NppFTPAboutHelper : NSObject
@property (assign) NSWindow* window;
+ (instancetype)shared;
- (void)visit:(id)s;
- (void)closeAbout:(id)s;
@end
@implementation NppFTPAboutHelper
+ (instancetype)shared { static NppFTPAboutHelper* s; if (!s) s = [[NppFTPAboutHelper alloc] init]; return s; }
- (void)visit:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/nextpad-plus-plus/NppFTP"]]; }
- (void)closeAbout:(id)s { [NSApp stopModal]; [self.window orderOut:nil]; }
@end

extern "C" NppData* NppFTP_HostData();
extern "C" void NppFTP_ShowProfileDialog(vProfile* profiles, FTPSettings* settings);
extern "C" void NppFTP_ShowGlobalSettings(FTPSettings* settings);
static intptr_t hostMsg(uint32_t msg, uintptr_t w, intptr_t l) {
	NppData* d = NppFTP_HostData();
	return d->_sendMessage(d->_nppHandle, msg, w, l);
}

// ───────────────────────────── ObjC bridge ─────────────────────────────────
// Data source/delegate for the remote tree + queue, and toolbar action target.
@interface NppFTPBridge : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSMenuDelegate>
@property (assign, nonatomic) FTPWindowController* ctrl;
@property (assign, nonatomic) NSOutlineView* outline;   // for context-menu hit-testing
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
- (void)tbSettings:(id)sender {
	// Present the two settings entry points (matching the Windows "Settings" split).
	NSMenu* m = [[NSMenu alloc] init];
	[[m addItemWithTitle:@"Profile settings…" action:@selector(tbProfileSettings:) keyEquivalent:@""] setTarget:self];
	[[m addItemWithTitle:@"Global settings…" action:@selector(tbGlobalSettings:) keyEquivalent:@""] setTarget:self];
	NSView* v = [sender isKindOfClass:[NSView class]] ? (NSView*)sender : nil;
	if (v) [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, v.bounds.size.height) inView:v];
	else   [m popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}
- (void)tbProfileSettings:(id)s { self.ctrl->ActionProfileSettings(); }
- (void)tbGlobalSettings:(id)s  { self.ctrl->ActionGlobalSettings(); }
- (void)tbMessages:(id)s   { self.ctrl->ActionMessagesToggle(); }

// context menu — rebuilt on each right-click for the hit FileObject
- (NSMenuItem*)addItem:(NSMenu*)m title:(NSString*)t sel:(SEL)s {
	NSMenuItem* i = [m addItemWithTitle:t action:s keyEquivalent:@""];
	i.target = self; return i;
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
	[menu removeAllItems];
	FileObject* root = self.ctrl->RootObject();
	if (!root) return;   // disconnected: no remote operations
	NSInteger row = self.outline.clickedRow;
	FileObject* fo = (row >= 0) ? (FileObject*)[(NSValue*)[self.outline itemAtRow:row] pointerValue] : root;
	if (!fo) fo = root;
	self.ctrl->SetContextTarget(fo);
	if (fo->isDir()) {
		[self addItem:menu title:@"Refresh" sel:@selector(ctxRefresh:)];
		[self addItem:menu title:@"Upload file here…" sel:@selector(ctxUpload:)];
		[self addItem:menu title:@"New directory…" sel:@selector(ctxMkdir:)];
		[self addItem:menu title:@"New file…" sel:@selector(ctxMkfile:)];
	} else {
		[self addItem:menu title:@"Download && open" sel:@selector(ctxDownloadOpen:)];
		[self addItem:menu title:@"Download to…" sel:@selector(ctxDownloadTo:)];
	}
	[menu addItem:[NSMenuItem separatorItem]];
	[self addItem:menu title:@"Rename…" sel:@selector(ctxRename:)];
	[self addItem:menu title:@"Delete" sel:@selector(ctxDelete:)];
	[self addItem:menu title:@"Permissions…" sel:@selector(ctxChmod:)];
}
- (void)ctxRefresh:(id)s      { self.ctrl->ActionRefreshDir(); }
- (void)ctxUpload:(id)s       { self.ctrl->ActionUploadTo(); }
- (void)ctxMkdir:(id)s        { self.ctrl->ActionMkDir(); }
- (void)ctxMkfile:(id)s       { self.ctrl->ActionMkFile(); }
- (void)ctxDownloadOpen:(id)s { self.ctrl->ActionDownloadOpen(); }
- (void)ctxDownloadTo:(id)s   { self.ctrl->ActionDownloadTo(); }
- (void)ctxRename:(id)s       { self.ctrl->ActionRename(); }
- (void)ctxDelete:(id)s       { self.ctrl->ActionDelete(); }
- (void)ctxChmod:(id)s        { self.ctrl->ActionChmod(); }

// queue table (one row per in-flight operation)
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)self.ctrl->QueueCount(); }
- (id)tableView:(NSTableView*)t objectValueForTableColumn:(NSTableColumn*)c row:(NSInteger)r {
	const FTPWindowController::ActiveOp* a = self.ctrl->QueueAt((size_t)r);
	if (!a) return @"";
	if ([c.identifier isEqual:@"Action"]) return [NSString stringWithUTF8String:a->action.c_str()];
	if ([c.identifier isEqual:@"Progress"]) return (a->progress > 0.0f) ? [NSString stringWithFormat:@"%.0f%%", a->progress] : @"";
	return [NSString stringWithUTF8String:a->file.c_str()];
}
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
		struct { const char* tip; const char* sym; SEL a; } btns[] = {
			{"Connect",    "bolt.horizontal.circle", @selector(tbConnect:)},
			{"Disconnect", "xmark.circle",           @selector(tbDisconnect:)},
			{"Download",   "arrow.down.circle",      @selector(tbDownload:)},
			{"Upload",     "arrow.up.circle",        @selector(tbUpload:)},
			{"Refresh",    "arrow.clockwise",        @selector(tbRefresh:)},
			{"Abort",      "stop.circle",            @selector(tbAbort:)},
			{"Settings",   "gearshape",              @selector(tbSettings:)},
			{"Messages",   "text.bubble",            @selector(tbMessages:)},
		};
		CGFloat x = 6;
		for (auto& b : btns) {
			NSButton* btn = [NSButton buttonWithTitle:@"" target:bridge action:b.a];
			NSImage* img = [NSImage imageWithSystemSymbolName:[NSString stringWithUTF8String:b.sym]
			                        accessibilityDescription:[NSString stringWithUTF8String:b.tip]];
			if (img) { btn.image = img; btn.imagePosition = NSImageOnly; }
			else     { btn.title = [NSString stringWithUTF8String:b.tip]; btn.font = [NSFont systemFontOfSize:9]; }
			btn.bezelStyle = NSBezelStyleRegularSquare; btn.bordered = NO;
			btn.toolTip = [NSString stringWithUTF8String:b.tip];
			btn.frame = NSMakeRect(x, 2, 28, 24);
			[tb addSubview:btn]; x += 30;
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
		bridge.outline = outline;
		NSMenu* ctx = [[NSMenu alloc] init]; ctx.delegate = bridge;
		outline.menu = ctx;
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
void FTPWindowController::ClearPending(QueueOperation* op) {
	if (!op) return;
	void (^drop)(void) = ^{
		for (size_t i = 0; i < m_activeOps.size(); i++) if (m_activeOps[i].op == op) { m_activeOps.erase(m_activeOps.begin()+i); break; }
		RefreshQueue();
	};
	if ([NSThread isMainThread]) drop(); else dispatch_async(dispatch_get_main_queue(), drop);
}

// Captures a human label (verb + file) for a queue op, for the transfer list.
static void describeOp(QueueOperation* op, std::string& action, std::string& file) {
	action = "Operation"; file = "";
	switch (op->GetType()) {
		case QueueOperation::QueueTypeConnect:    action = "Connect"; break;
		case QueueOperation::QueueTypeDisconnect: action = "Disconnect"; break;
		case QueueOperation::QueueTypeDownload:
		case QueueOperation::QueueTypeDownloadHandle:
			action = "Download"; file = ((QueueDownload*)op)->GetExternalPath() ?: ""; break;
		case QueueOperation::QueueTypeUpload:
			action = "Upload"; { const char* p = ((QueueUpload*)op)->GetExternalPath(); file = p ? p : ""; } break;
		case QueueOperation::QueueTypeDirectoryGet:
			action = "List"; file = ((QueueGetDir*)op)->GetDirPath() ?: ""; break;
		case QueueOperation::QueueTypeDirectoryCreate: action = "Make dir"; break;
		case QueueOperation::QueueTypeDirectoryRemove: action = "Remove dir"; break;
		case QueueOperation::QueueTypeFileCreate:      action = "Create file"; break;
		case QueueOperation::QueueTypeFileDelete:      action = "Delete"; break;
		case QueueOperation::QueueTypeFileRename:      action = "Rename"; break;
		case QueueOperation::QueueTypeFileChmod:       action = "Chmod"; break;
		default: break;
	}
}

// Ported from FTPWindow::OnEvent — dispatches a completed queue operation to the
// matching GUI update (populate tree on connect/list, open downloaded file, etc.).
void FTPWindowController::HandleNotification(int message, int code, QueueOperation* op) {
	if (!op) { RebuildTree(); return; }

	bool isStart = (message == (int)NotifyMessageStart);
	bool isEnd   = (message == (int)NotifyMessageEnd);

	// Maintain the in-flight transfer list (op is alive between Add and Remove —
	// QueueEventRemove blocks on ack before the queue deletes it).
	if (message == (int)NotifyMessageAdd) {
		ActiveOp a; a.op = op; a.progress = 0.0f; describeOp(op, a.action, a.file);
		m_activeOps.push_back(a);
		RefreshQueue(); return;
	}
	if (message == (int)NotifyMessageRemove) {
		for (size_t i = 0; i < m_activeOps.size(); i++) if (m_activeOps[i].op == op) { m_activeOps.erase(m_activeOps.begin()+i); break; }
		RefreshQueue(); return;
	}
	if (message == (int)NotifyMessageProgress) {
		for (auto& a : m_activeOps) if (a.op == op) { a.progress = op->GetProgress(); break; }
		RefreshQueue(); return;
	}
	if (isEnd) {  // clear progress; the matching Remove will drop the row
		for (auto& a : m_activeOps) if (a.op == op) { a.progress = 100.0f; break; }
	}

	int   queueResult = op->GetResult();
	void* queueData   = op->GetData();

	switch (op->GetType()) {
		case QueueOperation::QueueTypeConnect: {
			if (isStart) { AppendOutput(0, "[NppFTP] Connecting..."); break; }
			if (queueResult != -1) {
				AppendOutput(0, "[NppFTP] Connected");
				OnConnect(code);
			} else {
				AppendOutput(2, "[NppFTP] Unable to connect");
				OnDisconnect();
				if (m_session) m_session->TerminateSession();
			}
			break; }
		case QueueOperation::QueueTypeDisconnect: {
			if (isStart) break;
			AppendOutput(0, "[NppFTP] Disconnected.");
			OnDisconnect();
			break; }
		case QueueOperation::QueueTypeDirectoryGet: {
			if (isStart) break;
			QueueGetDir* dirop = (QueueGetDir*)op;
			// Refresh any intermediate parent directories carried by the op...
			std::vector<FTPDir*> parents = dirop->GetParentDirObjs();
			for (size_t i = 0; i < parents.size(); i++) {
				FTPDir* d = parents[i];
				FileObject* parent = m_session ? m_session->FindPathObject(d->dirPath) : nullptr;
				if (parent) OnDirectoryRefresh(parent, d->files, d->count);
			}
			if (queueResult == -1)
				AppendOutput(2, "[NppFTP] Failure retrieving directory contents");
			// ...then the requested directory itself.
			FTPFile*    files  = (FTPFile*)queueData;
			int         count  = dirop->GetFileCount();
			FileObject* parent = m_session ? m_session->FindPathObject(dirop->GetDirPath()) : nullptr;
			if (parent) OnDirectoryRefresh(parent, files, count);
			break; }
		case QueueOperation::QueueTypeDownloadHandle:
		case QueueOperation::QueueTypeDownload: {
			if (isStart) break;
			QueueDownload* opdld = (QueueDownload*)op;
			if (queueResult == -1) {
				AppendOutput(2, "[NppFTP] Download failed");
				break;
			}
			if (op->GetType() == QueueOperation::QueueTypeDownload) {
				if (code == 0) {
					// Download to cache: open the local file in the host editor.
					AppendOutput(0, "[NppFTP] Download succeeded, opening file.");
					hostMsg(NPPM_DOOPEN, 0, (intptr_t)opdld->GetLocalPath());
				} else {
					// Download to a chosen location: offer to open it.
					int ret = MessageBox(nullptr, "The download is complete. Do you wish to open the file?",
					                     "Download complete", MB_YESNO);
					if (ret == IDYES)
						hostMsg(NPPM_DOOPEN, 0, (intptr_t)opdld->GetLocalPath());
				}
			} else {
				AppendOutput(0, "[NppFTP] Download succeeded.");
			}
			break; }
		case QueueOperation::QueueTypeUpload: {
			if (isStart) break;
			if (queueResult == -1) { AppendOutput(2, "[NppFTP] Upload failed"); break; }
			QueueUpload* opuld = (QueueUpload*)op;
			AppendOutput(0, "[NppFTP] Upload succeeded.");
			// Refresh the remote parent directory of the uploaded file.
			char path[MAX_PATH];
			strncpy(path, opuld->GetExternalPath(), MAX_PATH - 1); path[MAX_PATH - 1] = 0;
			char* name = (char*)PU::FindExternalFilename(path);
			if (name) { *name = 0; if (m_session) m_session->GetDirectory(path); }
			break; }
		default:
			break;
	}
	RefreshQueue();
}

// ── engine-event handlers (ported from FTPWindow) ────────────────────────────
void FTPWindowController::OnConnect(int code) {
	m_selected = nullptr;
	if (code != 0) { RebuildTree(); return; }   // automated connect: no auto-list
	FileObject* root = m_session ? m_session->GetRootObject() : nullptr;
	RebuildTree();
	if (!root) return;
	// Walk to the deepest pre-seeded child (the profile's initial remote dir)
	// and list it, matching FTPWindow::OnConnect.
	FileObject* last = root;
	while (last->GetChildCount() > 0) last = last->GetChild(0);
	if (m_session) m_session->GetDirectory(last->GetPath());
}

void FTPWindowController::OnDisconnect() {
	m_selected = nullptr;
	RebuildTree();   // RootObject() is now null → outline falls back to the profile list
}

void FTPWindowController::OnDirectoryRefresh(FileObject* parent, FTPFile* files, int count) {
	if (!parent) return;
	parent->SetRefresh(false);
	// Delete the old children (the Cocoa outline holds no owning references — it
	// re-queries on reloadData — so freeing here is safe and avoids a leak).
	parent->RemoveAllChildren(true);
	for (int i = 0; i < count; i++)
		parent->AddChild(new FileObject(files + i));
	parent->Sort();
	RebuildTree();
}

void FTPWindowController::RefreshQueue() {
	@autoreleasepool { if (m_queueTable) [(__bridge NSTableView*)m_queueTable reloadData]; }
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
void FTPWindowController::ActionAbort() {
	if (!m_session) return;
	m_session->AbortTransfer();
	m_session->AbortOperation();
}
void FTPWindowController::ActionDownloadSelected() { if (m_selected) OnTreeActivate(m_selected); }
void FTPWindowController::ActionUploadCurrent() {
	char path[2048]; path[0] = 0;
	hostMsg(NPPM_GETFULLCURRENTPATH, sizeof(path), (intptr_t)path);
	// Upload-on-demand wiring (cache mapping) is completed with the dialogs.
}
void FTPWindowController::ActionProfileSettings() {
	NppFTP_ShowProfileDialog(m_profiles, m_settings);
	RebuildTree();   // profile list may have changed
}
void FTPWindowController::ActionGlobalSettings() {
	NppFTP_ShowGlobalSettings(m_settings);
}

// ── context-menu file operations ─────────────────────────────────────────────
// Remote paths are POSIX-style ('/'-separated); helpers compute parent/child.
static std::string ftpParentPath(const char* p) {
	std::string s(p && *p ? p : "/");
	if (s.size() > 1 && s.back() == '/') s.pop_back();
	size_t slash = s.find_last_of('/');
	if (slash == std::string::npos || slash == 0) return "/";
	return s.substr(0, slash);
}
static std::string ftpChildPath(const char* dir, const std::string& name) {
	std::string s(dir && *dir ? dir : "/");
	if (s.empty() || s.back() != '/') s += '/';
	return s + name;
}

void FTPWindowController::ActionRefreshDir() {
	if (m_session && m_selected && m_selected->isDir())
		m_session->GetDirectory(m_selected->GetPath());
}
void FTPWindowController::ActionUploadTo() {
	if (!m_session || !m_selected || !m_selected->isDir()) return;
	std::string dir = m_selected->GetPath();
	@autoreleasepool {
		NSOpenPanel* p = [NSOpenPanel openPanel];
		p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
		if ([p runModal] != NSModalResponseOK) return;
		std::string local = p.URL.path.UTF8String;
		m_session->UploadFile(local.c_str(), dir.c_str(), true);
		m_session->GetDirectory(dir.c_str());   // refresh after the upload completes (serial queue)
	}
}
void FTPWindowController::ActionMkDir() {
	if (!m_session || !m_selected || !m_selected->isDir()) return;
	std::string dir = m_selected->GetPath(), name;
	if (PromptInput(nullptr, "New directory", "Directory name:", "", false, name) != 1 || name.empty()) return;
	m_session->MkDir(ftpChildPath(dir.c_str(), name).c_str());
	m_session->GetDirectory(dir.c_str());
}
void FTPWindowController::ActionMkFile() {
	if (!m_session || !m_selected || !m_selected->isDir()) return;
	std::string dir = m_selected->GetPath(), name;
	if (PromptInput(nullptr, "New file", "File name:", "", false, name) != 1 || name.empty()) return;
	m_session->MkFile(ftpChildPath(dir.c_str(), name).c_str());
	m_session->GetDirectory(dir.c_str());
}
void FTPWindowController::ActionDownloadOpen() {
	if (m_session && m_selected && !m_selected->isDir())
		m_session->DownloadFileCache(m_selected->GetPath());
}
void FTPWindowController::ActionDownloadTo() {
	if (!m_session || !m_selected || m_selected->isDir()) return;
	std::string remote = m_selected->GetPath();
	@autoreleasepool {
		NSSavePanel* p = [NSSavePanel savePanel];
		p.nameFieldStringValue = [NSString stringWithUTF8String:m_selected->GetName()];
		if ([p runModal] != NSModalResponseOK) return;
		std::string local = p.URL.path.UTF8String;
		// code != 0 → HandleNotification asks before opening (download-to-location).
		m_session->DownloadFile(remote.c_str(), local.c_str(), false, 1);
	}
}
void FTPWindowController::ActionRename() {
	if (!m_session || !m_selected) return;
	std::string oldpath = m_selected->GetPath();
	std::string parent  = ftpParentPath(oldpath.c_str());
	std::string newname;
	if (PromptInput(nullptr, "Rename", "New name:", m_selected->GetName(), false, newname) != 1 || newname.empty()) return;
	m_session->Rename(oldpath.c_str(), ftpChildPath(parent.c_str(), newname).c_str());
	m_session->GetDirectory(parent.c_str());
}
void FTPWindowController::ActionDelete() {
	if (!m_session || !m_selected) return;
	std::string path = m_selected->GetPath();
	std::string parent = ftpParentPath(path.c_str());
	bool isDir = m_selected->isDir();
	std::string msg = std::string("Delete ") + (isDir ? "directory " : "file ") + m_selected->GetName() + "?";
	if (MessageBox(nullptr, msg.c_str(), "Confirm delete", MB_YESNO) != IDYES) return;
	if (isDir) m_session->RmDir(path.c_str());
	else       m_session->DeleteFile(path.c_str());
	m_session->GetDirectory(parent.c_str());
}
void FTPWindowController::ActionChmod() {
	if (!m_session || !m_selected) return;
	std::string path = m_selected->GetPath();
	std::string parent = ftpParentPath(path.c_str());
	std::string mode;
	if (PromptInput(nullptr, "Permissions", "Octal mode (e.g. 644):", "644", false, mode) != 1 || mode.empty()) return;
	m_session->Chmod(path.c_str(), mode.c_str());
	m_session->GetDirectory(parent.c_str());
}
void FTPWindowController::ActionMessagesToggle() {}

void FTPWindowController::OnTreeExpand(FileObject* fo) {
	if (m_session && m_session->IsConnected() && fo && fo->isDir())
		m_session->GetDirectory(fo->GetPath());
}

void FTPWindowController::OnTreeActivate(FileObject* fo) {
	if (!fo) return;
	m_selected = fo;
	if (fo->isDir()) {
		// toggle: collapse if expanded, else list + expand
		if (m_session) m_session->GetDirectory(fo->GetPath());
		return;
	}
	// Download to cache (notifies with code 0 → HandleNotification opens it via NPPM_DOOPEN).
	if (m_session) m_session->DownloadFileCache(fo->GetPath());
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
		NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,440,330)
			styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
		w.title = @"About NppFTP";
		NSView* v = w.contentView;

		NSString* msg =
			@"NppFTP — macOS port (Nextpad++), version 1.0.0\n"
			 "Based on NppFTP 0.30.22, Copyright 2010-2025\n"
			 "Created by Harry; maintained by Ashish Kulkarni and Christian Grasser.\n\n"
			 "Press “Show NppFTP Window” to get started. Enjoy transferring your "
			 "files from your favourite editor! =)\n\n"
			 "NppFTP works because of the effort put in the following libraries/projects:\n"
			 "  • Ultimate TCP/IP 4.2 (FTP/FTPS engine)\n"
			 "  • libssh (SFTP)\n"
			 "  • OpenSSL (TLS)\n"
			 "  • TinyXML 2.6.2\n"
			 "  • zlib";
		NSTextView* tv = [[NSTextView alloc] initWithFrame:NSMakeRect(12, 92, 416, 226)];
		tv.string = msg; tv.editable = NO; tv.drawsBackground = NO;
		tv.font = [NSFont systemFontOfSize:11];
		NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 92, 416, 226)];
		sc.documentView = tv; sc.hasVerticalScroller = YES; sc.drawsBackground = NO;
		[v addSubview:sc];

		NSString* zlibV = [NSString stringWithUTF8String:zlibVersion()];
		NSString* sshV  = [NSString stringWithUTF8String:ssh_version(0) ?: "libssh"];
		NSString* sslV  = [NSString stringWithUTF8String:OPENSSL_VERSION_TEXT];
		NSString* vers = [NSString stringWithFormat:@"zlib %@      %@      %@", zlibV, sshV, sslV];
		NSTextField* vl = [NSTextField labelWithString:vers];
		vl.frame = NSMakeRect(12, 56, 416, 16); vl.font = [NSFont systemFontOfSize:10];
		vl.textColor = [NSColor secondaryLabelColor];
		[v addSubview:vl];

		NSButton* visit = [NSButton buttonWithTitle:@"Visit NppFTP site"
			target:[NppFTPAboutHelper shared] action:@selector(visit:)];
		visit.frame = NSMakeRect(12, 12, 150, 28); visit.bezelStyle = NSBezelStyleRounded;
		[v addSubview:visit];

		NSButton* close = [NSButton buttonWithTitle:@"Close" target:[NppFTPAboutHelper shared] action:@selector(closeAbout:)];
		close.frame = NSMakeRect(340, 12, 88, 28); close.bezelStyle = NSBezelStyleRounded; close.keyEquivalent = @"\r";
		[v addSubview:close];
		[NppFTPAboutHelper shared].window = w;

		[w center];
		[NSApp runModalForWindow:w];
	}
}
