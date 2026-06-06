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
#include <algorithm>
#include <string>

// Tiny target for the About box's buttons (Close / Visit site).
@interface NppFTPAboutHelper : NSObject <NSWindowDelegate>
@property (assign) NSWindow* window;
+ (instancetype)shared;
- (void)visit:(id)s;
- (void)closeAbout:(id)s;
@end
@implementation NppFTPAboutHelper
+ (instancetype)shared { static NppFTPAboutHelper* s; if (!s) s = [[NppFTPAboutHelper alloc] init]; return s; }
- (void)visit:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/nextpad-plus-plus/NppFTP"]]; }
- (void)closeAbout:(id)s { [self.window close]; }   // → windowWillClose:
- (void)windowWillClose:(NSNotification*)n { [NSApp stopModal]; }
@end

extern "C" NppData* NppFTP_HostData();
extern "C" void NppFTP_ShowProfileSettings(FTPProfile* profile);
extern "C" void NppFTP_ShowGlobalSettings(FTPSettings* settings);
extern "C" void NppFTP_SaveSettings();

static NSString* nsutf8(const char* s) { return [NSString stringWithUTF8String:s ? s : ""]; }

// ── disconnected "Profiles" tree model ──────────────────────────────────────
// Folders are encoded in each profile's group path (FTPProfile::GetParent(),
// e.g. "" = top level, "/Work" = a folder). An EMPTY folder persists as a
// "dummy" profile (empty name, Parent = the folder path) — exactly as upstream
// NppFTP does. The tree is rebuilt from the profile list on each refresh.
struct ProfileNode {
	std::string name;       // display name (folder name, or profile name)
	std::string path;       // group path of THIS node ("" root, "/Work", "/A/B")
	bool        isFolder;
	FTPProfile* profile;    // leaf → the profile; folder → backing dummy or null
	std::vector<ProfileNode*> children;
};

static void freeProfileTree(ProfileNode* n) {
	if (!n) return;
	for (auto c : n->children) freeProfileTree(c);
	delete n;
}
// Walk/create the folder chain for a group path; returns the deepest folder node.
static ProfileNode* ensureFolder(ProfileNode* root, const std::string& path) {
	ProfileNode* cur = root;
	std::string accum;
	size_t i = 0;
	while (i < path.size()) {
		if (path[i] == '/') { i++; continue; }
		size_t j = path.find('/', i);
		std::string comp = path.substr(i, (j == std::string::npos ? path.size() : j) - i);
		i = (j == std::string::npos) ? path.size() : j;
		accum += "/" + comp;
		ProfileNode* next = nullptr;
		for (auto c : cur->children) if (c->isFolder && c->name == comp) { next = c; break; }
		if (!next) { next = new ProfileNode{comp, accum, true, nullptr, {}}; cur->children.push_back(next); }
		cur = next;
	}
	return cur;
}
static void sortProfileNode(ProfileNode* n) {
	std::sort(n->children.begin(), n->children.end(), [](ProfileNode* a, ProfileNode* b) {
		if (a->isFolder != b->isFolder) return a->isFolder > b->isFolder;   // folders first
		return a->name < b->name;
	});
	for (auto c : n->children) sortProfileNode(c);
}
static ProfileNode* buildProfileTree(vProfile* profiles) {
	ProfileNode* root = new ProfileNode{"Profiles", "", true, nullptr, {}};
	if (profiles) for (FTPProfile* p : *profiles) {
		std::string parentPath = (p->GetParent() ? p->GetParent() : "");
		ProfileNode* folder = ensureFolder(root, parentPath);
		if (!p->GetName() || strlen(p->GetName()) == 0)
			folder->profile = p;                 // dummy: backs this (possibly empty) folder
		else
			folder->children.push_back(new ProfileNode{p->GetName(), parentPath, false, p, {}});
	}
	sortProfileNode(root);
	return root;
}
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

// Connected → the remote FileObject tree (root = session RootObject).
// Disconnected → the "Profiles" folder tree (ProfileNode*, built from groups).
- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item {
	FTPWindowController* c = self.ctrl;
	if (c->RootObject()) {  // connected
		FileObject* fo = item ? (FileObject*)[(NSValue*)item pointerValue] : c->RootObject();
		return fo ? fo->GetChildCount() : 0;
	}
	ProfileNode* root = (ProfileNode*)c->ProfileTree();
	if (!root) return 0;
	if (!item) return 1;    // the single "Profiles" root row
	ProfileNode* n = (ProfileNode*)[(NSValue*)item pointerValue];
	return (NSInteger)n->children.size();
}
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item {
	FTPWindowController* c = self.ctrl;
	if (c->RootObject()) { FileObject* fo = (FileObject*)[(NSValue*)item pointerValue]; return fo && fo->isDir(); }
	ProfileNode* n = (ProfileNode*)[(NSValue*)item pointerValue];
	return n && n->isFolder;
}
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)index ofItem:(id)item {
	FTPWindowController* c = self.ctrl;
	if (c->RootObject()) {
		FileObject* parent = item ? (FileObject*)[(NSValue*)item pointerValue] : c->RootObject();
		return [NSValue valueWithPointer:parent->GetChild((int)index)];
	}
	if (!item) return [NSValue valueWithPointer:c->ProfileTree()];   // root node
	ProfileNode* n = (ProfileNode*)[(NSValue*)item pointerValue];
	return [NSValue valueWithPointer:n->children[(size_t)index]];
}
- (id)outlineView:(NSOutlineView*)ov objectValueForTableColumn:(NSTableColumn*)col byItem:(id)item {
	FTPWindowController* c = self.ctrl;
	if (c->RootObject()) {
		FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
		return fo ? nsutf8(fo->GetName()) : @"";
	}
	ProfileNode* n = (ProfileNode*)[(NSValue*)item pointerValue];
	return n ? nsutf8(n->name.c_str()) : @"";
}
// Icon + name per row (folder for "Profiles"/folders/dirs, globe for profiles, file icon).
- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(id)item {
	NSTableCellView* cell = [ov makeViewWithIdentifier:@"NppFTPCell" owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 240, 18)];
		cell.identifier = @"NppFTPCell";
		NSImageView* iv = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 1, 16, 16)];
		[cell addSubview:iv]; cell.imageView = iv;
		NSTextField* tf = [NSTextField labelWithString:@""];
		tf.frame = NSMakeRect(22, 0, 216, 17); tf.font = [NSFont systemFontOfSize:12];
		tf.autoresizingMask = NSViewWidthSizable; tf.lineBreakMode = NSLineBreakByTruncatingTail;
		[cell addSubview:tf]; cell.textField = tf;
	}
	NSString* name = @""; NSImage* icon = nil;
	FTPWindowController* c = self.ctrl;
	if (c->RootObject()) {                       // connected remote tree
		FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
		name = fo ? nsutf8(fo->GetName()) : @"";
		icon = (fo && fo->isDir()) ? [NSImage imageNamed:NSImageNameFolder]
		                           : [[NSWorkspace sharedWorkspace] iconForFileType:name.pathExtension ?: @""];
	} else {                                     // disconnected profile tree
		ProfileNode* n = (ProfileNode*)[(NSValue*)item pointerValue];
		if (n) name = nsutf8(n->name.c_str());
		icon = (n && n->isFolder) ? [NSImage imageNamed:NSImageNameFolder]
		     : ([NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:@"profile"]
		        ?: [NSImage imageNamed:NSImageNameNetwork]);
	}
	cell.textField.stringValue = name;
	cell.imageView.image = icon;
	return cell;
}
- (void)outlineViewItemWillExpand:(NSNotification*)n {
	if (!self.ctrl->RootObject()) return;   // Profiles folder: nothing to lazy-load
	id item = n.userInfo[@"NSObject"];
	FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
	if (fo) self.ctrl->OnTreeExpand(fo);
}
- (void)onOutlineDoubleClick:(NSOutlineView*)ov {
	NSInteger row = ov.clickedRow;
	if (row < 0) return;
	id item = [ov itemAtRow:row];
	FTPWindowController* c = self.ctrl;
	if (c->RootObject()) {   // connected: open/expand remote item
		FileObject* fo = (FileObject*)[(NSValue*)item pointerValue];
		if (fo) c->OnTreeActivate(fo);
		return;
	}
	// disconnected: double-click a profile leaf → Connect (Win default action)
	ProfileNode* n = (ProfileNode*)[(NSValue*)item pointerValue];
	if (n && !n->isFolder && n->profile) c->ActionConnectProfile(n->profile);
}

// toolbar actions
- (void)tbConnect:(id)s    { self.ctrl->ActionConnectSelected(); }
- (void)tbDisconnect:(id)s { self.ctrl->ActionDisconnect(); }
- (void)tbDownload:(id)s   { self.ctrl->ActionDownloadSelected(); }
- (void)tbUpload:(id)s     { self.ctrl->ActionUploadCurrent(); }
- (void)tbRefresh:(id)s    { self.ctrl->ActionRefresh(); }
- (void)tbAbort:(id)s      { self.ctrl->ActionAbort(); }
- (void)tbSettings:(id)sender { self.ctrl->ActionGlobalSettings(); }   // gear → Global settings
- (void)tbMessages:(id)s   { self.ctrl->ActionMessagesToggle(); }

// context menu — rebuilt on each right-click for the hit FileObject
- (NSMenuItem*)addItem:(NSMenu*)m title:(NSString*)t sel:(SEL)s {
	NSMenuItem* i = [m addItemWithTitle:t action:s keyEquivalent:@""];
	i.target = self; return i;
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
	[menu removeAllItems];
	FTPWindowController* c = self.ctrl;
	NSInteger row = self.outline.clickedRow;

	if (!c->RootObject()) {
		// ── disconnected: profile / folder menus (mirror Windows) ─────────────
		ProfileNode* root = (ProfileNode*)c->ProfileTree();
		ProfileNode* n = (row >= 0) ? (ProfileNode*)[(NSValue*)[self.outline itemAtRow:row] pointerValue] : root;
		if (!n) n = root;
		c->SetContextNode((void*)n);
		BOOL pasteOK = c->ClipboardActive();
		if (n->isFolder) {
			[self addItem:menu title:@"Create new Profile" sel:@selector(ctxCreateProfile:)];
			NSMenuItem* mkf = [self addItem:menu title:@"Create new Folder" sel:@selector(ctxCreateFolder:)];
			mkf.attributedTitle = [[NSAttributedString alloc] initWithString:@"Create new Folder"
				attributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]}];
			if (n != root) {   // sub-folder: rename/delete/copy/cut
				[self addItem:menu title:@"Rename Folder" sel:@selector(ctxRenameFolder:)];
				[self addItem:menu title:@"Delete Folder" sel:@selector(ctxDeleteFolder:)];
				[menu addItem:[NSMenuItem separatorItem]];
				[self addItem:menu title:@"Copy Folder" sel:@selector(ctxCopyNode:)];
				[self addItem:menu title:@"Cut Folder" sel:@selector(ctxCutNode:)];
			}
			[menu addItem:[NSMenuItem separatorItem]];
			NSMenuItem* paste = [self addItem:menu title:@"Paste" sel:@selector(ctxPaste:)];
			paste.enabled = pasteOK;
			return;
		}
		// profile leaf
		NSMenuItem* connect = [self addItem:menu title:@"Connect" sel:@selector(ctxConnectProfile:)];
		connect.attributedTitle = [[NSAttributedString alloc] initWithString:@"Connect"
			attributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]}];
		[self addItem:menu title:@"Edit Profile" sel:@selector(ctxEditProfile:)];
		[menu addItem:[NSMenuItem separatorItem]];
		[self addItem:menu title:@"Rename Profile" sel:@selector(ctxRenameProfile:)];
		[self addItem:menu title:@"Delete Profile" sel:@selector(ctxDeleteProfile:)];
		[menu addItem:[NSMenuItem separatorItem]];
		[self addItem:menu title:@"Copy Profile" sel:@selector(ctxCopyNode:)];
		[self addItem:menu title:@"Cut Profile" sel:@selector(ctxCutNode:)];
		return;
	}

	// ── connected: remote file/dir operations ────────────────────────────────
	FileObject* root = c->RootObject();
	FileObject* fo = (row >= 0) ? (FileObject*)[(NSValue*)[self.outline itemAtRow:row] pointerValue] : root;
	if (!fo) fo = root;
	c->SetContextTarget(fo);
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
- (void)ctxCreateProfile:(id)s  { self.ctrl->ActionCreateProfileHere(); }
- (void)ctxCreateFolder:(id)s   { self.ctrl->ActionCreateFolder(); }
- (void)ctxConnectProfile:(id)s { self.ctrl->ActionConnectContextProfile(); }
- (void)ctxEditProfile:(id)s    { self.ctrl->ActionEditContextProfile(); }
- (void)ctxRenameProfile:(id)s  { self.ctrl->ActionRenameContextProfile(); }
- (void)ctxDeleteProfile:(id)s  { self.ctrl->ActionDeleteContextProfile(); }
- (void)ctxRenameFolder:(id)s   { self.ctrl->ActionRenameFolder(); }
- (void)ctxDeleteFolder:(id)s   { self.ctrl->ActionDeleteFolder(); }
- (void)ctxCutNode:(id)s        { self.ctrl->ActionCutContext(); }
- (void)ctxCopyNode:(id)s       { self.ctrl->ActionCopyContext(); }
- (void)ctxPaste:(id)s          { self.ctrl->ActionPasteInto(); }
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
	  m_outputView(nullptr), m_outputPanel(nullptr), m_outputHandle(nullptr), m_outputVisible(false),
	  m_bridge(nullptr), m_toolbar(nullptr), m_panelHandle(nullptr),
	  m_rootObj(nullptr), m_selected(nullptr), m_profileTree(nullptr), m_treeConnectedMode(false),
	  m_pendingTerminate(false),
	  m_contextProfile(nullptr), m_contextIsFolder(false), m_contextIsRoot(false),
	  m_clipProfile(nullptr), m_clipIsCut(false), m_visible(false) {}

FTPWindowController::~FTPWindowController() {}

FileObject* FTPWindowController::RootObject() {
	// CHEAP cached accessor — never touch the network here. (FTPSession::GetRootObject
	// runs Cwd/Pwd commands and rebuilds the tree; it must be called exactly once on
	// connect, NOT on every NSOutlineView query / RebuildTree.)
	return (m_session && m_session->IsConnected()) ? m_rootObj : nullptr;
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
		struct { const char* tip; const char* sym; SEL a; bool needsConn; } btns[] = {
			{"Connect",    "bolt.horizontal.circle", @selector(tbConnect:),    false},
			{"Disconnect", "xmark.circle",           @selector(tbDisconnect:), true},
			{"Download",   "arrow.down.circle",      @selector(tbDownload:),   true},
			{"Upload",     "arrow.up.circle",        @selector(tbUpload:),     true},
			{"Refresh",    "arrow.clockwise",        @selector(tbRefresh:),    true},
			{"Abort",      "stop.circle",            @selector(tbAbort:),      true},
			{"Settings",   "gearshape",              @selector(tbSettings:),   false},
			{"Messages",   "text.bubble",            @selector(tbMessages:),   false},
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
			btn.tag = b.needsConn ? 1 : 0;   // 1 = disabled while disconnected
			btn.frame = NSMakeRect(x, 2, 28, 24);
			[tb addSubview:btn]; x += 30;
		}
		m_toolbar = (void*)CFBridgingRetain(tb);
		[panel addSubview:tb];

		// remote tree (taller now that the Output lives in its own panel)
		NSScrollView* treeScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 110, 320, 460)];
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

		m_panelView = (void*)CFBridgingRetain(panel);

		// ── separate "NppFTP - Output" dock panel (toggled by the Messages button,
		//    like the Windows Output window / AnalysePlugin) ──────────────────────
		NSView* outPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 220)];
		NSScrollView* oScroll = [[NSScrollView alloc] initWithFrame:outPanel.bounds];
		oScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		oScroll.hasVerticalScroller = YES; oScroll.borderType = NSNoBorder;
		NSTextView* tv = [[NSTextView alloc] initWithFrame:oScroll.bounds];
		tv.editable = NO; tv.font = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont systemFontOfSize:11];
		tv.minSize = NSMakeSize(0, 0); tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
		tv.verticallyResizable = YES; tv.horizontallyResizable = NO;
		tv.autoresizingMask = NSViewWidthSizable;
		oScroll.documentView = tv;
		[outPanel addSubview:oScroll];
		m_outputView  = (void*)CFBridgingRetain(tv);
		m_outputPanel = (void*)CFBridgingRetain(outPanel);

		// Register both docked panels (host strong-retains the views; both start hidden).
		m_panelHandle  = (void*)hostMsg(NPPM_DMM_REGISTERPANEL, (uintptr_t)panel,    (intptr_t)"NppFTP");
		m_outputHandle = (void*)hostMsg(NPPM_DMM_REGISTERPANEL, (uintptr_t)outPanel, (intptr_t)"NppFTP - Output");
	}
	return 0;
}

int FTPWindowController::Init(FTPSession* session, vProfile* vProfiles, FTPSettings* ftpSettings) {
	m_session = session; m_profiles = vProfiles; m_settings = ftpSettings;
	RebuildTree();
	return 0;
}

int FTPWindowController::Destroy() {
	if (m_panelHandle)  hostMsg(NPPM_DMM_UNREGISTERPANEL, (uintptr_t)m_panelHandle, 0);
	if (m_outputHandle) hostMsg(NPPM_DMM_UNREGISTERPANEL, (uintptr_t)m_outputHandle, 0);
	freeProfileTree((ProfileNode*)m_profileTree); m_profileTree = nullptr;
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
	bool connected = (RootObject() != nullptr);
	@autoreleasepool {
		NSOutlineView* ov = (__bridge NSOutlineView*)m_outline;
		if (!connected) {
			// We're about to FREE + rebuild the ProfileNode tree. NSOutlineView
			// lazily retains item pointers (for expansion state / itemAtRow:), so
			// it would keep handing back freed ProfileNode* after the rebuild —
			// reading node->profile from freed memory and crashing on the next
			// click. Drop the outline's items FIRST (detach the data source →
			// reloadData releases them), THEN free + rebuild.
			if (ov) { id ds = ov.dataSource; ov.dataSource = nil; [ov reloadData]; ov.dataSource = ds; }
			freeProfileTree((ProfileNode*)m_profileTree);
			m_profileTree = buildProfileTree(m_profiles);
		} else if (connected != m_treeConnectedMode && ov) {
			// Just switched to connected: drop the old ProfileNode* items before
			// the outline re-queries them as FileObject* (wrong-type cast → crash).
			id ds = ov.dataSource; ov.dataSource = nil; [ov reloadData]; ov.dataSource = ds;
		}
		m_treeConnectedMode = connected;
		if (ov) {
			[ov reloadData];
			if (!connected && m_profileTree)   // show "Profiles" expanded by default
				[ov expandItem:[NSValue valueWithPointer:m_profileTree]];
		}
	}
	UpdateToolbarState();
}

// Guard against a stale context pointer (tree freed/rebuilt under an open menu):
// pointer-compare only (never deref p), so it's safe even if p is garbage.
bool FTPWindowController::profileInList(FTPProfile* p) {
	if (!p || !m_profiles) return false;
	for (FTPProfile* x : *m_profiles) if (x == p) return true;
	return false;
}

void FTPWindowController::UpdateToolbarState() {
	@autoreleasepool {
		NSView* tb = (__bridge NSView*)m_toolbar;
		if (!tb) return;
		BOOL connected = (m_session && m_session->IsConnected());
		for (NSView* sv in tb.subviews)
			if ([sv isKindOfClass:[NSButton class]] && sv.tag == 1)
				((NSButton*)sv).enabled = connected;
	}
}

void FTPWindowController::AppendOutput(int type, const char* msg) {
	@autoreleasepool {
		NSTextView* tv = (__bridge NSTextView*)m_outputView;
		if (!tv) return;
		// Each line is timestamped HH:mm:ss, matching the Windows Output window.
		static NSDateFormatter* df = nil;
		if (!df) { df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; }
		NSString* ts   = [df stringFromDate:[NSDate date]];
		NSString* line = [NSString stringWithFormat:@"%@  %s\n", ts, msg ? msg : ""];
		NSColor* color = (type == 2 /*Output_Err*/) ? [NSColor systemRedColor] : [NSColor textColor];
		NSDictionary* attrs = @{ NSForegroundColorAttributeName: color,
		                         NSFontAttributeName: (tv.font ?: [NSFont systemFontOfSize:11]) };
		[tv.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attrs]];
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
		RefreshQueue();
		// Deferred teardown: this op is about to be deleted and the worker will go
		// idle (m_performing=false) right after we ack below — only then is it safe
		// to TerminateSession (which Deinitialize-waits on the worker).
		if (m_pendingTerminate) {
			m_pendingTerminate = false;
			FTPSession* s = m_session;
			dispatch_async(dispatch_get_main_queue(), ^{ if (s) s->TerminateSession(); });
		}
		return;
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
				// Do NOT TerminateSession() here: it deletes the queue (incl. THIS
				// still-performing op) and waits on the worker, which is blocked on
				// this very notification's ack → deadlock/use-after-free. Flag it;
				// we tear down once the op's Remove fires and the worker is idle.
				m_pendingTerminate = true;
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
	// THE one and only GetRootObject() call (runs Cwd/Pwd + builds the root tree).
	FileObject* root = m_session ? m_session->GetRootObject() : nullptr;
	m_rootObj = root;                            // cache it for the cheap RootObject()
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
	m_rootObj  = nullptr;   // the session is tearing down its root tree; drop our ref
	RebuildTree();          // RootObject() is now null → outline falls back to profiles
}

void FTPWindowController::OnDirectoryRefresh(FileObject* parent, FTPFile* files, int count) {
	if (!parent) return;
	parent->SetRefresh(false);
	// Detach (don't delete) the old children: the NSOutlineView retains item
	// identities (FileObject* wrapped in NSValue) for expansion state, so freeing
	// them here would leave stale pointers it dereferences on the next reload.
	// (Matches upstream NppFTP, which also passes false.)
	parent->RemoveAllChildren(false);
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
	if (!m_session || !m_profiles || m_profiles->empty()) return;
	@autoreleasepool {
		NSOutlineView* ov = (__bridge NSOutlineView*)m_outline;
		NSInteger row = ov.selectedRow;
		if (row >= 0) {   // connect the selected profile leaf
			ProfileNode* n = (ProfileNode*)[(NSValue*)[ov itemAtRow:row] pointerValue];
			if (n && !n->isFolder && n->profile) { ActionConnectProfile(n->profile); return; }
		}
		ActionConnectProfile(m_profiles->at(0));   // fall back to the first profile
	}
}
void FTPWindowController::ActionDisconnect() {
	// Defer: if a queue op is mid-flight (worker blocked on a pending ack),
	// TerminateSession would delete it and crash the ack. Let pending UI
	// notifications drain first, then tear down.
	FTPSession* s = m_session;
	FTPWindowController* self = this;
	dispatch_async(dispatch_get_main_queue(), ^{ if (s) { s->TerminateSession(); self->RebuildTree(); } });
}
void FTPWindowController::ActionRefresh() {
	if (m_session && m_session->IsConnected()) m_session->GetDirectory("/");
}
void FTPWindowController::ActionAbort() {
	// AbortTransfer/AbortOperation deref m_transferWrapper/m_mainWrapper, which
	// only exist while connected — guard to avoid a null deref when idle.
	if (!m_session || !m_session->IsConnected()) return;
	m_session->AbortTransfer();
	m_session->AbortOperation();
}
void FTPWindowController::ActionDownloadSelected() { if (m_selected) OnTreeActivate(m_selected); }
void FTPWindowController::ActionUploadCurrent() {
	char path[2048]; path[0] = 0;
	hostMsg(NPPM_GETFULLCURRENTPATH, sizeof(path), (intptr_t)path);
	// Upload-on-demand wiring (cache mapping) is completed with the dialogs.
}
void FTPWindowController::ActionGlobalSettings() {
	NppFTP_ShowGlobalSettings(m_settings);
}

// ── profile-tree actions (disconnected panel: folders + profiles + clipboard) ─
// Group-path helpers. The root folder has path "" (== a profile's default
// Parent). A folder under it is "/Name"; nested is "/A/B".
static bool groupIsDescendant(const std::string& path, const std::string& folder) {
	// true if `path` is `folder` itself or lives under it
	if (path == folder) return true;
	std::string prefix = folder + "/";
	return path.compare(0, prefix.size(), prefix) == 0;
}
static std::string groupChild(const std::string& base, const std::string& name) {
	return base + "/" + name;            // "" + "/x" = "/x"; "/a" + "/x" = "/a/x"
}
static std::string groupParent(const std::string& folder) {
	size_t slash = folder.find_last_of('/');
	return (slash == std::string::npos) ? "" : folder.substr(0, slash);
}
static std::string groupLeafName(const std::string& folder) {
	size_t slash = folder.find_last_of('/');
	return (slash == std::string::npos) ? folder : folder.substr(slash + 1);
}
// Is there already a folder with this exact group path among the profiles?
static bool groupExists(vProfile* profiles, const std::string& path) {
	for (FTPProfile* p : *profiles) {
		std::string par = p->GetParent() ? p->GetParent() : "";
		if (groupIsDescendant(par, path)) return true;
	}
	return false;
}

void FTPWindowController::SetContextNode(void* node) {
	ProfileNode* n = (ProfileNode*)node;
	ProfileNode* root = (ProfileNode*)m_profileTree;
	m_contextIsRoot   = (n == root);
	m_contextIsFolder = n ? n->isFolder : false;
	if (n && n->isFolder) {
		m_contextFolderPath = n->path;        // "" for root, "/Foo" for a folder
		m_contextProfile    = n->profile;     // the folder's backing dummy (or null)
	} else if (n) {
		m_contextFolderPath = n->path;        // the leaf's group path (its folder)
		m_contextProfile    = n->profile;
	}
}

void FTPWindowController::ActionCreateProfileHere() {
	if (!m_profiles || !m_settings) return;
	FTPProfile* p = new FTPProfile("New profile");
	p->SetCacheParent(m_settings->GetGlobalCache());
	p->SetParent(m_contextFolderPath.c_str());   // "" = top level, "/Foo" = a folder
	m_profiles->push_back(p); p->AddRef();
	RebuildTree();
	NppFTP_ShowProfileSettings(p);               // open the editor right after creating
	NppFTP_SaveSettings();
	RebuildTree();
}
void FTPWindowController::ActionCreateFolder() {
	if (!m_profiles) return;
	// Pick a unique "New Folder" name under the context folder.
	std::string base = m_contextFolderPath, path = groupChild(base, "New Folder");
	for (int i = 2; groupExists(m_profiles, path); i++)
		path = groupChild(base, std::string("New Folder ") + std::to_string(i));
	FTPProfile* dummy = new FTPProfile("");       // empty name → backs an empty folder
	dummy->SetParent(path.c_str());
	m_profiles->push_back(dummy); dummy->AddRef();
	NppFTP_SaveSettings();
	RebuildTree();
}
void FTPWindowController::ActionConnectProfile(FTPProfile* p) {
	if (!m_session || !profileInList(p)) return;   // p may be a stale node pointer
	m_session->StartSession(p);
	m_session->Connect();
}
void FTPWindowController::ActionConnectContextProfile() { ActionConnectProfile(m_contextProfile); }
void FTPWindowController::ActionEditContextProfile() {
	if (!profileInList(m_contextProfile)) return;
	NppFTP_ShowProfileSettings(m_contextProfile);   // saves on close
	RebuildTree();
}
void FTPWindowController::ActionRenameContextProfile() {
	if (!profileInList(m_contextProfile)) return;
	std::string name;
	if (PromptInput(nullptr, "Rename profile", "New name:", m_contextProfile->GetName(), false, name) != 1 || name.empty()) return;
	m_contextProfile->SetName(name.c_str());
	NppFTP_SaveSettings();
	RebuildTree();
}
void FTPWindowController::ActionDeleteContextProfile() {
	if (!profileInList(m_contextProfile) || !m_profiles) return;
	std::string msg = std::string("Delete profile \"") + m_contextProfile->GetName() + "\"?";
	if (MessageBox(nullptr, msg.c_str(), "Confirm delete", MB_YESNO) != IDYES) return;
	for (size_t i = 0; i < m_profiles->size(); i++)
		if (m_profiles->at(i) == m_contextProfile) {
			FTPProfile* p = m_profiles->at(i);
			m_profiles->erase(m_profiles->begin() + i); p->Release();
			break;
		}
	m_contextProfile = nullptr;
	NppFTP_SaveSettings();
	RebuildTree();
}
void FTPWindowController::ActionRenameFolder() {
	if (!m_profiles || m_contextFolderPath.empty()) return;   // can't rename root
	std::string oldPath = m_contextFolderPath, name;
	if (PromptInput(nullptr, "Rename folder", "New name:", groupLeafName(oldPath).c_str(), false, name) != 1 || name.empty()) return;
	std::string newPath = groupChild(groupParent(oldPath), name);
	if (newPath == oldPath) return;
	for (FTPProfile* p : *m_profiles) {     // rewrite the group-path prefix on all descendants
		std::string par = p->GetParent() ? p->GetParent() : "";
		if (par == oldPath)                 p->SetParent(newPath.c_str());
		else if (groupIsDescendant(par, oldPath))
			p->SetParent((newPath + par.substr(oldPath.size())).c_str());
	}
	NppFTP_SaveSettings();
	RebuildTree();
}
void FTPWindowController::ActionDeleteFolder() {
	if (!m_profiles || m_contextFolderPath.empty()) return;
	std::string folder = m_contextFolderPath;
	if (MessageBox(nullptr, "Delete this folder and all profiles inside it?", "Confirm delete", MB_YESNO) != IDYES) return;
	for (size_t i = m_profiles->size(); i-- > 0; ) {
		std::string par = m_profiles->at(i)->GetParent() ? m_profiles->at(i)->GetParent() : "";
		if (groupIsDescendant(par, folder)) {
			FTPProfile* p = m_profiles->at(i);
			m_profiles->erase(m_profiles->begin() + i); p->Release();
		}
	}
	m_contextProfile = nullptr;
	NppFTP_SaveSettings();
	RebuildTree();
}
void FTPWindowController::ActionCutContext()  {
	m_clipProfile = m_contextIsFolder ? nullptr : m_contextProfile;
	m_clipFolderPath = m_contextIsFolder ? m_contextFolderPath : "";
	m_clipIsCut = true;
}
void FTPWindowController::ActionCopyContext() {
	m_clipProfile = m_contextIsFolder ? nullptr : m_contextProfile;
	m_clipFolderPath = m_contextIsFolder ? m_contextFolderPath : "";
	m_clipIsCut = false;
}
void FTPWindowController::ActionPasteInto() {
	if (!m_profiles || !m_settings) return;
	std::string target = m_contextFolderPath;   // paste into the right-clicked folder
	if (m_clipProfile && !profileInList(m_clipProfile)) { m_clipProfile = nullptr; return; }   // stale
	if (m_clipProfile) {                         // ── a profile on the clipboard ──
		if (m_clipIsCut) {
			m_clipProfile->SetParent(target.c_str());           // move
		} else {
			FTPProfile* p = new FTPProfile(m_clipProfile->GetName(), m_clipProfile);  // duplicate
			p->SetCacheParent(m_settings->GetGlobalCache());
			p->SetParent(target.c_str());
			m_profiles->push_back(p); p->AddRef();
		}
	} else if (!m_clipFolderPath.empty()) {      // ── a folder on the clipboard ──
		std::string src = m_clipFolderPath;
		std::string dst = groupChild(target, groupLeafName(src));
		if (groupIsDescendant(dst, src)) return;            // can't paste a folder into itself
		if (m_clipIsCut) {
			for (FTPProfile* p : *m_profiles) {
				std::string par = p->GetParent() ? p->GetParent() : "";
				if (par == src)                  p->SetParent(dst.c_str());
				else if (groupIsDescendant(par, src))
					p->SetParent((dst + par.substr(src.size())).c_str());
			}
		} else {   // copy the whole subtree
			std::vector<FTPProfile*> dups;
			for (FTPProfile* p : *m_profiles) {
				std::string par = p->GetParent() ? p->GetParent() : "";
				if (!groupIsDescendant(par, src)) continue;
				std::string np = (par == src) ? dst : (dst + par.substr(src.size()));
				FTPProfile* c = new FTPProfile(p->GetName(), p);
				c->SetCacheParent(m_settings->GetGlobalCache());
				c->SetParent(np.c_str()); c->AddRef();
				dups.push_back(c);
			}
			for (FTPProfile* c : dups) m_profiles->push_back(c);
		}
	} else return;
	if (m_clipIsCut) { m_clipProfile = nullptr; m_clipFolderPath.clear(); }
	NppFTP_SaveSettings();
	RebuildTree();
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
void FTPWindowController::ActionMessagesToggle() {
	m_outputVisible = !m_outputVisible;
	if (m_outputHandle)
		hostMsg(m_outputVisible ? NPPM_DMM_SHOWPANEL : NPPM_DMM_HIDEPANEL, (uintptr_t)m_outputHandle, 0);
}

void FTPWindowController::OnTreeExpand(FileObject* fo) {
	if (m_session && m_session->IsConnected() && fo && fo->isDir())
		m_session->GetDirectory(fo->GetPath());
}

void FTPWindowController::OnTreeActivate(FileObject* fo) {
	if (!fo || !m_session || !m_session->IsConnected()) return;
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
		w.releasedWhenClosed = NO;
		w.delegate = [NppFTPAboutHelper shared];
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
