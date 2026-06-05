/*
 * ProfileDialog.mm — Cocoa "Profile settings" (5 tabs) + "Global settings"
 * dialogs for the NppFTP macOS port. Faithful to the Windows resource layout
 * (IDD_DIALOG_PROFILES* / IDD_DIALOG_GLOBAL): a profile list on the left with
 * Add new / Rename / Copy / Delete, and a 5-tab editor on the right
 * (Connection / Authentication / Transfers / FTP / Cache).
 *
 * Profiles are edited live (writing straight into the FTPProfile objects) and
 * persisted via NppFTP_SaveSettings on close, matching the upstream behaviour.
 *
 * NppFTP macOS port 2026 (GPL v3).
 */
#import <Cocoa/Cocoa.h>
#include "StdInc.h"
#include "FTPProfile.h"
#include "FTPSettings.h"
#include "FTPCache.h"

extern "C" void NppFTP_SaveSettings();

// ────────────────────────── small layout helpers ───────────────────────────
static NSTextField* mkLabel(NSView* parent, NSString* s, CGFloat x, CGFloat y, CGFloat w) {
	NSTextField* l = [NSTextField labelWithString:s];
	l.frame = NSMakeRect(x, y, w, 17);
	l.font = [NSFont systemFontOfSize:11];
	[parent addSubview:l];
	return l;
}
static NSTextField* mkEdit(NSView* parent, CGFloat x, CGFloat y, CGFloat w, BOOL secure) {
	NSTextField* t = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(x,y,w,22)]
	                        : [[NSTextField alloc] initWithFrame:NSMakeRect(x,y,w,22)];
	t.font = [NSFont systemFontOfSize:11];
	[parent addSubview:t];
	return t;
}
static NSButton* mkCheck(NSView* parent, NSString* s, CGFloat x, CGFloat y, CGFloat w) {
	NSButton* b = [NSButton checkboxWithTitle:s target:nil action:nil];
	b.frame = NSMakeRect(x, y, w, 18);
	b.font = [NSFont systemFontOfSize:11];
	[parent addSubview:b];
	return b;
}
static NSButton* mkRadio(NSView* parent, NSString* s, CGFloat x, CGFloat y, CGFloat w) {
	NSButton* b = [NSButton radioButtonWithTitle:s target:nil action:nil];
	b.frame = NSMakeRect(x, y, w, 18);
	b.font = [NSFont systemFontOfSize:11];
	[parent addSubview:b];
	return b;
}
static NSString* sutf8(const char* s) { return [NSString stringWithUTF8String:s ? s : ""]; }

// ───────────────────────────── the dialog ──────────────────────────────────
@interface NppFTPProfileDialog : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate> {
	vProfile*     _profiles;
	FTPSettings*  _settings;
	FTPProfile*   _cur;
	BOOL          _loading;
}
@property (strong) NSWindow* window;
@property (strong) NSTableView* profileTable;
// Connection
@property (strong) NSTextField* edHost; @property (strong) NSPopUpButton* cbSecurity;
@property (strong) NSTextField* edPort; @property (strong) NSTextField* edUser;
@property (strong) NSTextField* edPass; @property (strong) NSButton* ckAskPass;
@property (strong) NSTextField* edTimeout; @property (strong) NSTextField* edInitDir;
@property (strong) NSTextField* edNoop;
// Authentication
@property (strong) NSButton* ckKey; @property (strong) NSButton* ckPassword; @property (strong) NSButton* ckInteractive;
@property (strong) NSTextField* edKeyFile; @property (strong) NSTextField* edPassphrase; @property (strong) NSButton* ckAskPassphrase;
// Transfers
@property (strong) NSButton* rbActive; @property (strong) NSButton* rbPassive;
@property (strong) NSButton* rbAscii; @property (strong) NSButton* rbBinary;
@property (strong) NSTableView* asciiList; @property (strong) NSTableView* binaryList;
@property (strong) NSTextField* edAddAscii; @property (strong) NSTextField* edAddBinary;
@property (strong) NSTextField* edPortMin; @property (strong) NSTextField* edPortMax;
// FTP misc
@property (strong) NSTextField* edListParams; @property (strong) NSTextField* edParent;
// Cache
@property (strong) NSTableView* cacheList; @property (strong) NSTextField* edCacheLocal; @property (strong) NSTextField* edCacheExternal;
@end

@implementation NppFTPProfileDialog

- (instancetype)initWithProfiles:(vProfile*)p settings:(FTPSettings*)s {
	if ((self = [super init])) { _profiles = p; _settings = s; _cur = nullptr; }
	return self;
}

- (FTPProfile*)current { return _cur; }

// ── build UI ────────────────────────────────────────────────────────────────
- (void)build {
	NSRect frame = NSMakeRect(0, 0, 720, 470);
	self.window = [[NSWindow alloc] initWithContentRect:frame
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
		backing:NSBackingStoreBuffered defer:NO];
	self.window.title = @"Profile settings";
	self.window.releasedWhenClosed = NO;
	self.window.delegate = self;   // windowWillClose: ends the modal session
	NSView* root = self.window.contentView;

	// left: profiles list + buttons
	mkLabel(root, @"Profiles:", 12, 444, 80);
	NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 70, 170, 372)];
	sc.hasVerticalScroller = YES; sc.borderType = NSBezelBorder;
	NSTableView* pt = [[NSTableView alloc] initWithFrame:sc.bounds];
	NSTableColumn* pc = [[NSTableColumn alloc] initWithIdentifier:@"name"]; pc.width = 150;
	[pt addTableColumn:pc]; pt.headerView = nil;
	pt.dataSource = self; pt.delegate = self;
	sc.documentView = pt; [root addSubview:sc];
	self.profileTable = pt;

	struct { NSString* t; SEL a; CGFloat x; CGFloat w; } pbtns[] = {
		{@"Add new", @selector(addProfile:), 12, 56},
		{@"Rename",  @selector(renameProfile:), 70, 52},
		{@"Copy",    @selector(copyProfile:), 124, 40},
		{@"Delete",  @selector(deleteProfile:), 12, 56},
	};
	for (int i = 0; i < 4; i++) {
		CGFloat y = (i < 3) ? 44 : 22;
		NSButton* b = [NSButton buttonWithTitle:pbtns[i].t target:self action:pbtns[i].a];
		b.frame = NSMakeRect(pbtns[i].x, y, pbtns[i].w, 22); b.font = [NSFont systemFontOfSize:11];
		b.bezelStyle = NSBezelStyleRounded;
		[root addSubview:b];
	}

	// right: tab view
	NSTabView* tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(196, 50, 512, 404)];
	[tabs addTabViewItem:[self tabConnection]];
	[tabs addTabViewItem:[self tabAuth]];
	[tabs addTabViewItem:[self tabTransfers]];
	[tabs addTabViewItem:[self tabFTP]];
	[tabs addTabViewItem:[self tabCache]];
	[root addSubview:tabs];

	// close
	NSButton* close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeDialog:)];
	close.frame = NSMakeRect(620, 12, 88, 28); close.bezelStyle = NSBezelStyleRounded;
	close.keyEquivalent = @"\r";
	[root addSubview:close];

	[self selectFirst];
}

- (NSTabViewItem*)tabConnection {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"conn"]; it.label = @"Connection";
	NSView* v = it.view;
	mkLabel(v, @"Hostname:", 12, 336, 120);
	self.edHost = mkEdit(v, 12, 314, 220, NO); self.edHost.delegate = self;
	mkLabel(v, @"Connection type:", 260, 336, 120);
	self.cbSecurity = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(260, 312, 160, 25)];
	[self.cbSecurity addItemsWithTitles:@[@"FTP", @"FTPES", @"FTPS", @"SFTP"]];
	self.cbSecurity.target = self; self.cbSecurity.action = @selector(securityChanged:);
	[v addSubview:self.cbSecurity];
	mkLabel(v, @"Port:", 12, 286, 120);
	self.edPort = mkEdit(v, 12, 264, 80, NO); self.edPort.delegate = self;
	mkLabel(v, @"Username:", 12, 238, 120);
	self.edUser = mkEdit(v, 12, 216, 220, NO); self.edUser.delegate = self;
	mkLabel(v, @"Password:", 12, 190, 120);
	self.edPass = mkEdit(v, 12, 168, 220, YES); self.edPass.delegate = self;
	self.ckAskPass = mkCheck(v, @"Ask for password", 260, 170, 180); self.ckAskPass.target = self; self.ckAskPass.action = @selector(commit);
	mkLabel(v, @"Timeout (seconds):", 12, 142, 140);
	self.edTimeout = mkEdit(v, 12, 120, 80, NO); self.edTimeout.delegate = self;
	mkLabel(v, @"Initial remote directory:", 12, 94, 180);
	self.edInitDir = mkEdit(v, 12, 72, 360, NO); self.edInitDir.delegate = self;
	mkLabel(v, @"Keep-alive every N seconds (server must support NOOP; 0 = off):", 80, 30, 420);
	self.edNoop = mkEdit(v, 12, 26, 60, NO); self.edNoop.delegate = self;
	return it;
}

- (NSTabViewItem*)tabAuth {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"auth"]; it.label = @"Authentication";
	NSView* v = it.view;
	self.ckKey = mkCheck(v, @"Try private key file authentication", 12, 336, 320);
	self.ckPassword = mkCheck(v, @"Try password authentication", 12, 312, 320);
	self.ckInteractive = mkCheck(v, @"Try keyboard interactive authentication", 12, 288, 320);
	for (NSButton* b in @[self.ckKey, self.ckPassword, self.ckInteractive]) { b.target = self; b.action = @selector(commit); }
	mkLabel(v, @"Private key file:", 12, 252, 160);
	self.edKeyFile = mkEdit(v, 12, 230, 420, NO); self.edKeyFile.delegate = self;
	NSButton* kb = [NSButton buttonWithTitle:@"…" target:self action:@selector(browseKeyFile:)];
	kb.frame = NSMakeRect(438, 230, 36, 22); kb.bezelStyle = NSBezelStyleRounded; [v addSubview:kb];
	mkLabel(v, @"Passphrase:", 12, 198, 120);
	self.edPassphrase = mkEdit(v, 12, 176, 300, YES); self.edPassphrase.delegate = self;
	self.ckAskPassphrase = mkCheck(v, @"Ask every time", 320, 178, 150); self.ckAskPassphrase.target = self; self.ckAskPassphrase.action = @selector(commit);
	return it;
}

- (NSTabViewItem*)tabTransfers {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"xfer"]; it.label = @"Transfers";
	NSView* v = it.view;
	NSBox* box1 = [[NSBox alloc] initWithFrame:NSMakeRect(12, 300, 150, 70)]; box1.title = @"Connection mode"; [v addSubview:box1];
	self.rbActive = mkRadio(box1, @"Active", 12, 28, 100); self.rbActive.target = self; self.rbActive.action = @selector(commit);
	self.rbPassive = mkRadio(box1, @"Passive", 12, 6, 100); self.rbPassive.target = self; self.rbPassive.action = @selector(commit);
	NSBox* box2 = [[NSBox alloc] initWithFrame:NSMakeRect(180, 300, 150, 70)]; box2.title = @"Transfer mode"; [v addSubview:box2];
	self.rbAscii = mkRadio(box2, @"ASCII", 12, 28, 100); self.rbAscii.target = self; self.rbAscii.action = @selector(commit);
	self.rbBinary = mkRadio(box2, @"Binary", 12, 6, 100); self.rbBinary.target = self; self.rbBinary.action = @selector(commit);

	mkLabel(v, @"ASCII types:", 12, 274, 120);
	NSScrollView* a = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 150, 220, 120)];
	a.hasVerticalScroller = YES; a.borderType = NSBezelBorder;
	self.asciiList = [[NSTableView alloc] initWithFrame:a.bounds];
	NSTableColumn* ac = [[NSTableColumn alloc] initWithIdentifier:@"a"]; ac.width = 200; [self.asciiList addTableColumn:ac];
	self.asciiList.headerView = nil; self.asciiList.dataSource = self; self.asciiList.delegate = self;
	self.asciiList.target = self; self.asciiList.doubleAction = @selector(removeAscii:);
	a.documentView = self.asciiList; [v addSubview:a];

	mkLabel(v, @"Binary types:", 250, 274, 120);
	NSScrollView* b = [[NSScrollView alloc] initWithFrame:NSMakeRect(250, 150, 220, 120)];
	b.hasVerticalScroller = YES; b.borderType = NSBezelBorder;
	self.binaryList = [[NSTableView alloc] initWithFrame:b.bounds];
	NSTableColumn* bc = [[NSTableColumn alloc] initWithIdentifier:@"b"]; bc.width = 200; [self.binaryList addTableColumn:bc];
	self.binaryList.headerView = nil; self.binaryList.dataSource = self; self.binaryList.delegate = self;
	self.binaryList.target = self; self.binaryList.doubleAction = @selector(removeBinary:);
	b.documentView = self.binaryList; [v addSubview:b];

	mkLabel(v, @"Add ASCII (Enter):", 12, 124, 160);
	self.edAddAscii = mkEdit(v, 12, 102, 220, NO); self.edAddAscii.target = self; self.edAddAscii.action = @selector(addAscii:);
	mkLabel(v, @"Add Binary (Enter):", 250, 124, 160);
	self.edAddBinary = mkEdit(v, 250, 102, 220, NO); self.edAddBinary.target = self; self.edAddBinary.action = @selector(addBinary:);

	NSBox* box3 = [[NSBox alloc] initWithFrame:NSMakeRect(12, 20, 458, 70)]; box3.title = @"Active transfer port range"; [v addSubview:box3];
	mkLabel(box3, @"Min port (>1000):", 12, 14, 120);
	self.edPortMin = mkEdit(box3, 130, 10, 70, NO); self.edPortMin.delegate = self;
	mkLabel(box3, @"Max port (<65000):", 220, 14, 130);
	self.edPortMax = mkEdit(box3, 350, 10, 70, NO); self.edPortMax.delegate = self;
	return it;
}

- (NSTabViewItem*)tabFTP {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"ftp"]; it.label = @"FTP";
	NSView* v = it.view;
	mkLabel(v, @"LIST parameters:", 12, 336, 160);
	self.edListParams = mkEdit(v, 12, 314, 360, NO); self.edListParams.delegate = self;
	mkLabel(v, @"Hint: try \"-al\" to show hidden files", 12, 292, 360);
	mkLabel(v, @"Groupname (submenu):", 12, 256, 200);
	self.edParent = mkEdit(v, 12, 234, 360, NO); self.edParent.delegate = self;
	mkLabel(v, @"Hint: groups this profile under a submenu", 12, 212, 360);
	return it;
}

- (NSTabViewItem*)tabCache {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"cache"]; it.label = @"Cache";
	NSView* v = it.view;
	mkLabel(v, @"Profile cache maps:", 12, 336, 200);
	NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 170, 458, 160)];
	sc.hasVerticalScroller = YES; sc.borderType = NSBezelBorder;
	self.cacheList = [[NSTableView alloc] initWithFrame:sc.bounds];
	NSTableColumn* lc = [[NSTableColumn alloc] initWithIdentifier:@"local"]; lc.title = @"Local path"; lc.width = 220;
	NSTableColumn* ec = [[NSTableColumn alloc] initWithIdentifier:@"ext"]; ec.title = @"External path"; ec.width = 220;
	[self.cacheList addTableColumn:lc]; [self.cacheList addTableColumn:ec];
	self.cacheList.dataSource = self; self.cacheList.delegate = self;
	sc.documentView = self.cacheList; [v addSubview:sc];

	mkLabel(v, @"Local path:", 12, 142, 100);
	self.edCacheLocal = mkEdit(v, 100, 140, 280, NO);
	NSButton* cb = [NSButton buttonWithTitle:@"…" target:self action:@selector(browseCacheLocal:)];
	cb.frame = NSMakeRect(388, 140, 36, 22); cb.bezelStyle = NSBezelStyleRounded; [v addSubview:cb];
	mkLabel(v, @"External path:", 12, 112, 100);
	self.edCacheExternal = mkEdit(v, 100, 110, 280, NO);

	struct { NSString* t; SEL a; CGFloat x; } cbtns[] = {
		{@"Add new", @selector(cacheAdd:), 12}, {@"Edit", @selector(cacheEdit:), 90}, {@"Delete", @selector(cacheDelete:), 150},
	};
	for (int i = 0; i < 3; i++) {
		NSButton* b = [NSButton buttonWithTitle:cbtns[i].t target:self action:cbtns[i].a];
		b.frame = NSMakeRect(cbtns[i].x, 76, (i==2?64:(i==0?72:56)), 24); b.bezelStyle = NSBezelStyleRounded;
		[v addSubview:b];
	}
	return it;
}

// ── profile list ──────────────────────────────────────────────────────────
- (void)selectFirst {
	[self.profileTable reloadData];
	if (!_profiles->empty()) { [self.profileTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; }
	else { _cur = nullptr; [self load]; }
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t {
	if (t == self.profileTable) return _profiles->size();
	if (t == self.asciiList)  return _cur ? _cur->GetAsciiCount() : 0;
	if (t == self.binaryList) return _cur ? _cur->GetBinaryCount() : 0;
	if (t == self.cacheList)  return (_cur && _cur->GetCache()) ? _cur->GetCache()->GetPathMapCount() : 0;
	return 0;
}
- (id)tableView:(NSTableView*)t objectValueForTableColumn:(NSTableColumn*)c row:(NSInteger)r {
	if (t == self.profileTable) return sutf8(_profiles->at(r)->GetName());
	if (t == self.asciiList)  return sutf8(_cur->GetAsciiType((int)r));
	if (t == self.binaryList) return sutf8(_cur->GetBinaryType((int)r));
	if (t == self.cacheList) {
		const PathMap& pm = _cur->GetCache()->GetPathMap((int)r);
		return [c.identifier isEqual:@"local"] ? sutf8(pm.localpath) : sutf8(pm.externalpath);
	}
	return @"";
}
- (void)tableViewSelectionDidChange:(NSNotification*)n {
	if (n.object != self.profileTable) return;
	NSInteger r = self.profileTable.selectedRow;
	_cur = (r >= 0 && (size_t)r < _profiles->size()) ? _profiles->at(r) : nullptr;
	[self load];
}

// ── load / commit ───────────────────────────────────────────────────────────
- (void)load {
	_loading = YES;
	BOOL on = (_cur != nullptr);
	for (NSView* sv in @[self.edHost, self.cbSecurity, self.edPort, self.edUser, self.edPass, self.ckAskPass,
	                     self.edTimeout, self.edInitDir, self.edNoop, self.ckKey, self.ckPassword, self.ckInteractive,
	                     self.edKeyFile, self.edPassphrase, self.ckAskPassphrase, self.rbActive, self.rbPassive,
	                     self.rbAscii, self.rbBinary, self.edPortMin, self.edPortMax, self.edListParams, self.edParent])
		((NSControl*)sv).enabled = on;
	if (!_cur) {
		for (NSTextField* f in @[self.edHost, self.edPort, self.edUser, self.edPass, self.edTimeout, self.edInitDir,
		                         self.edNoop, self.edKeyFile, self.edPassphrase, self.edPortMin, self.edPortMax,
		                         self.edListParams, self.edParent]) f.stringValue = @"";
		[self.asciiList reloadData]; [self.binaryList reloadData]; [self.cacheList reloadData];
		_loading = NO; return;
	}
	self.edHost.stringValue = sutf8(_cur->GetHostname());
	[self.cbSecurity selectItemAtIndex:(NSInteger)_cur->GetSecurityMode()];
	self.edPort.stringValue = [NSString stringWithFormat:@"%d", _cur->GetPort()];
	self.edUser.stringValue = sutf8(_cur->GetUsername());
	self.edPass.stringValue = sutf8(_cur->GetPassword());
	self.ckAskPass.state = _cur->GetAskPassword() ? NSControlStateValueOn : NSControlStateValueOff;
	self.edTimeout.stringValue = [NSString stringWithFormat:@"%d", _cur->GetTimeout()];
	self.edInitDir.stringValue = sutf8(_cur->GetInitialDir());
	self.edNoop.stringValue = [NSString stringWithFormat:@"%d", _cur->GetNoOp()];
	AuthenticationMethods m = _cur->GetAcceptedMethods();
	self.ckKey.state = (m & Method_Key) ? NSControlStateValueOn : NSControlStateValueOff;
	self.ckPassword.state = (m & Method_Password) ? NSControlStateValueOn : NSControlStateValueOff;
	self.ckInteractive.state = (m & Method_Interactive) ? NSControlStateValueOn : NSControlStateValueOff;
	self.edKeyFile.stringValue = sutf8(_cur->GetKeyFile());
	self.edPassphrase.stringValue = sutf8(_cur->GetPassphrase());
	self.ckAskPassphrase.state = _cur->GetAskPassphrase() ? NSControlStateValueOn : NSControlStateValueOff;
	BOOL active = (_cur->GetConnectionMode() == Mode_Active);
	self.rbActive.state = active ? NSControlStateValueOn : NSControlStateValueOff;
	self.rbPassive.state = active ? NSControlStateValueOff : NSControlStateValueOn;
	BOOL ascii = (_cur->GetTransferMode() == Mode_ASCII);
	self.rbAscii.state = ascii ? NSControlStateValueOn : NSControlStateValueOff;
	self.rbBinary.state = ascii ? NSControlStateValueOff : NSControlStateValueOn;
	int pmin = 0, pmax = 0; _cur->GetDataPortRange(&pmin, &pmax);
	self.edPortMin.stringValue = [NSString stringWithFormat:@"%d", pmin];
	self.edPortMax.stringValue = [NSString stringWithFormat:@"%d", pmax];
	self.edListParams.stringValue = sutf8(_cur->GetListParams());
	self.edParent.stringValue = sutf8(_cur->GetParent());
	[self.asciiList reloadData]; [self.binaryList reloadData]; [self.cacheList reloadData];
	_loading = NO;
}

- (void)commit {
	if (_loading || !_cur) return;
	_cur->SetHostname(self.edHost.stringValue.UTF8String);
	_cur->SetSecurityMode((Security_Mode)self.cbSecurity.indexOfSelectedItem);
	_cur->SetPort(self.edPort.intValue);
	_cur->SetUsername(self.edUser.stringValue.UTF8String);
	_cur->SetPassword(self.edPass.stringValue.UTF8String);
	_cur->SetAskPassword(self.ckAskPass.state == NSControlStateValueOn);
	_cur->SetTimeout(self.edTimeout.intValue);
	_cur->SetInitialDir(self.edInitDir.stringValue.UTF8String);
	_cur->SetNoOp(self.edNoop.intValue);
	int methods = 0;
	if (self.ckKey.state == NSControlStateValueOn) methods |= Method_Key;
	if (self.ckPassword.state == NSControlStateValueOn) methods |= Method_Password;
	if (self.ckInteractive.state == NSControlStateValueOn) methods |= Method_Interactive;
	_cur->SetAcceptedMethods((AuthenticationMethods)methods);
	_cur->SetKeyFile(self.edKeyFile.stringValue.UTF8String);
	_cur->SetPassphrase(self.edPassphrase.stringValue.UTF8String);
	_cur->SetAskPassphrase(self.ckAskPassphrase.state == NSControlStateValueOn);
	_cur->SetConnectionMode(self.rbActive.state == NSControlStateValueOn ? Mode_Active : Mode_Passive);
	_cur->SetTransferMode(self.rbAscii.state == NSControlStateValueOn ? Mode_ASCII : Mode_Binary);
	_cur->SetDataPortRange(self.edPortMin.intValue, self.edPortMax.intValue);
	_cur->SetListParams(self.edListParams.stringValue.UTF8String);
	_cur->SetParent(self.edParent.stringValue.UTF8String);
	[self.profileTable reloadData];
}
- (void)controlTextDidEndEditing:(NSNotification*)n { [self commit]; }
- (void)securityChanged:(id)s {
	// default the port when switching between FTP-family (21) and SFTP (22)
	int cur = self.edPort.intValue;
	if (cur == 21 || cur == 22 || cur == 0)
		self.edPort.stringValue = (self.cbSecurity.indexOfSelectedItem == Mode_SFTP) ? @"22" : @"21";
	[self commit];
}

// ── profile list actions ────────────────────────────────────────────────────
- (NSString*)promptName:(NSString*)title initial:(NSString*)initial {
	NSAlert* a = [[NSAlert alloc] init]; a.messageText = title;
	NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)];
	f.stringValue = initial ?: @""; a.accessoryView = f;
	[a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
	if ([a runModal] == NSAlertFirstButtonReturn && f.stringValue.length) return f.stringValue;
	return nil;
}
- (void)addProfile:(id)s {
	NSString* name = [self promptName:@"New profile name:" initial:@""];
	if (!name) return;
	FTPProfile* p = new FTPProfile(name.UTF8String);
	p->SetCacheParent(_settings->GetGlobalCache());
	_profiles->push_back(p); p->AddRef();
	[self.profileTable reloadData];
	[self.profileTable selectRowIndexes:[NSIndexSet indexSetWithIndex:_profiles->size()-1] byExtendingSelection:NO];
}
- (void)copyProfile:(id)s {
	if (!_cur) return;
	NSString* name = [self promptName:@"Copied profile name:" initial:[sutf8(_cur->GetName()) stringByAppendingString:@" copy"]];
	if (!name) return;
	FTPProfile* p = new FTPProfile(name.UTF8String, _cur);
	p->SetCacheParent(_settings->GetGlobalCache());
	_profiles->push_back(p); p->AddRef();
	[self.profileTable reloadData];
	[self.profileTable selectRowIndexes:[NSIndexSet indexSetWithIndex:_profiles->size()-1] byExtendingSelection:NO];
}
- (void)renameProfile:(id)s {
	if (!_cur) return;
	NSString* name = [self promptName:@"Rename profile:" initial:sutf8(_cur->GetName())];
	if (!name) return;
	_cur->SetName(name.UTF8String);
	[self.profileTable reloadData];
}
- (void)deleteProfile:(id)s {
	NSInteger r = self.profileTable.selectedRow;
	if (r < 0 || (size_t)r >= _profiles->size()) return;
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = @"Delete profile?"; a.informativeText = sutf8(_profiles->at(r)->GetName());
	[a addButtonWithTitle:@"Delete"]; [a addButtonWithTitle:@"Cancel"];
	if ([a runModal] != NSAlertFirstButtonReturn) return;
	FTPProfile* p = _profiles->at(r);
	_profiles->erase(_profiles->begin() + r); p->Release();
	_cur = nullptr;
	[self.profileTable reloadData];
	[self selectFirst];
}

// ── ascii/binary type lists ──────────────────────────────────────────────────
- (void)addAscii:(id)s {
	if (!_cur) return;
	NSString* t = self.edAddAscii.stringValue;
	if (!t.length) return;
	if (![t hasPrefix:@"."]) t = [@"." stringByAppendingString:t];
	_cur->AddAsciiType(t.UTF8String); self.edAddAscii.stringValue = @""; [self.asciiList reloadData];
}
- (void)addBinary:(id)s {
	if (!_cur) return;
	NSString* t = self.edAddBinary.stringValue;
	if (!t.length) return;
	if (![t hasPrefix:@"."]) t = [@"." stringByAppendingString:t];
	_cur->AddBinaryType(t.UTF8String); self.edAddBinary.stringValue = @""; [self.binaryList reloadData];
}
- (void)removeAscii:(id)s {
	NSInteger r = self.asciiList.clickedRow;
	if (_cur && r >= 0 && r < _cur->GetAsciiCount()) { _cur->RemoveAsciiType(_cur->GetAsciiType((int)r)); [self.asciiList reloadData]; }
}
- (void)removeBinary:(id)s {
	NSInteger r = self.binaryList.clickedRow;
	if (_cur && r >= 0 && r < _cur->GetBinaryCount()) { _cur->RemoveBinaryType(_cur->GetBinaryType((int)r)); [self.binaryList reloadData]; }
}

// ── cache maps ───────────────────────────────────────────────────────────────
- (void)cacheAdd:(id)s {
	if (!_cur || !_cur->GetCache()) return;
	NSString* l = self.edCacheLocal.stringValue, *e = self.edCacheExternal.stringValue;
	if (!l.length || !e.length) return;
	PathMap pm; pm.localpath = strdup(l.UTF8String); pm.localpathExpanded = NULL; pm.externalpath = strdup(e.UTF8String);
	_cur->GetCache()->AddPathMap(pm);
	self.edCacheLocal.stringValue = @""; self.edCacheExternal.stringValue = @""; [self.cacheList reloadData];
}
- (void)cacheEdit:(id)s {
	NSInteger r = self.cacheList.selectedRow;
	if (!_cur || !_cur->GetCache() || r < 0) return;
	NSString* l = self.edCacheLocal.stringValue, *e = self.edCacheExternal.stringValue;
	if (!l.length || !e.length) return;
	PathMap pm; pm.localpath = strdup(l.UTF8String); pm.localpathExpanded = NULL; pm.externalpath = strdup(e.UTF8String);
	_cur->GetCache()->SetPathMap(pm, (int)r); [self.cacheList reloadData];
}
- (void)cacheDelete:(id)s {
	NSInteger r = self.cacheList.selectedRow;
	if (_cur && _cur->GetCache() && r >= 0) { _cur->GetCache()->DeletePathMap((int)r); [self.cacheList reloadData]; }
}
- (void)browseCacheLocal:(id)s {
	NSOpenPanel* p = [NSOpenPanel openPanel]; p.canChooseDirectories = YES; p.canChooseFiles = NO;
	if ([p runModal] == NSModalResponseOK) self.edCacheLocal.stringValue = p.URL.path;
}
- (void)browseKeyFile:(id)s {
	NSOpenPanel* p = [NSOpenPanel openPanel]; p.canChooseFiles = YES; p.canChooseDirectories = NO;
	if ([p runModal] == NSModalResponseOK) { self.edKeyFile.stringValue = p.URL.path; [self commit]; }
}

// ── close ─────────────────────────────────────────────────────────────────
- (void)closeDialog:(id)s { [self.window close]; }   // → windowWillClose:
- (void)windowWillClose:(NSNotification*)n {
	if (n.object != self.window) return;
	[self commit];              // persist on ANY close path (button or title-bar)
	NppFTP_SaveSettings();
	[NSApp stopModal];
}
@end

// ────────────────────────── Global settings dialog ─────────────────────────
@interface NppFTPGlobalDialog : NSObject <NSWindowDelegate> {
	FTPSettings* _settings;
}
@property (strong) NSWindow* window;
@property (strong) NSTextField* edCache;
@property (strong) NSButton* ckClear;
@property (strong) NSButton* ckNoRecycle;
@property (strong) NSTextField* edMaster;
@property (strong) NSButton* ckDebug;
@end

@implementation NppFTPGlobalDialog
- (instancetype)initWithSettings:(FTPSettings*)s { if ((self=[super init])) _settings=s; return self; }
- (void)build {
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,440,260)
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
	self.window.title = @"Global settings";
	self.window.releasedWhenClosed = NO;
	self.window.delegate = self;
	NSView* v = self.window.contentView;
	mkLabel(v, @"Global cache:", 16, 224, 120);
	self.edCache = mkEdit(v, 16, 202, 360, NO);
	self.edCache.stringValue = sutf8(_settings->GetGlobalCachePath());
	self.ckClear = mkCheck(v, @"Clear ENTIRE cache on disconnect (use with care!)", 16, 172, 400);
	self.ckClear.state = _settings->GetClearCache() ? NSControlStateValueOn : NSControlStateValueOff;
	self.ckNoRecycle = mkCheck(v, @"Do not use the recycle bin (delete permanently)", 32, 150, 400);
	self.ckNoRecycle.state = _settings->GetClearCachePermanent() ? NSControlStateValueOn : NSControlStateValueOff;
	mkLabel(v, @"Master password (max 8 characters):", 16, 120, 300);
	self.edMaster = mkEdit(v, 16, 98, 360, YES);
	mkLabel(v, @"Blank → a default key is used. Otherwise you are asked on each start.", 16, 76, 400);
	self.ckDebug = mkCheck(v, @"Verbose console (for debugging)", 16, 48, 300);
	self.ckDebug.state = FTPSettings::GetDebugMode() ? NSControlStateValueOn : NSControlStateValueOff;
	NSButton* ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(ok:)];
	ok.frame = NSMakeRect(340, 12, 88, 28); ok.bezelStyle = NSBezelStyleRounded; ok.keyEquivalent = @"\r";
	[v addSubview:ok];
}
- (void)ok:(id)s {
	_settings->SetGlobalCachePath(self.edCache.stringValue.UTF8String);
	_settings->SetClearCache(self.ckClear.state == NSControlStateValueOn);
	_settings->SetClearCachePermanent(self.ckNoRecycle.state == NSControlStateValueOn);
	FTPSettings::SetDebugMode(self.ckDebug.state == NSControlStateValueOn);
	NSString* mp = self.edMaster.stringValue;
	if (mp.length) { char key[8] = {0}; strncpy(key, mp.UTF8String, 8); _settings->SetEncryptionKey(key); }
	NppFTP_SaveSettings();
	[self.window close];   // → windowWillClose:
}
- (void)windowWillClose:(NSNotification*)n {
	if (n.object == self.window) [NSApp stopModal];
}
@end

// ────────────────────────── C++ entry points ───────────────────────────────
extern "C" void NppFTP_ShowProfileDialog(vProfile* profiles, FTPSettings* settings) {
	@autoreleasepool {
		NppFTPProfileDialog* d = [[NppFTPProfileDialog alloc] initWithProfiles:profiles settings:settings];
		[d build];
		[d.window center];
		[NSApp runModalForWindow:d.window];
	}
}
extern "C" void NppFTP_ShowGlobalSettings(FTPSettings* settings) {
	@autoreleasepool {
		NppFTPGlobalDialog* d = [[NppFTPGlobalDialog alloc] initWithSettings:settings];
		[d build];
		[d.window center];
		[NSApp runModalForWindow:d.window];
	}
}
