/*
 * ProfileDialog.mm — Cocoa "Profile settings" (single profile, 5 tabs) +
 * "Global settings" dialogs for the NppFTP macOS port. Faithful to the Windows
 * IDD_DIALOG_PROFILES_SINGLE / IDD_DIALOG_GLOBAL layouts: the profile editor
 * edits ONE profile (no embedded list) — all profile management is driven from
 * the dock panel's tree context menu (Create / Edit / Connect / Rename / …).
 *
 * The profile is edited live (written straight into the FTPProfile) and
 * persisted via NppFTP_SaveSettings on close, matching upstream behaviour.
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
	l.font = [NSFont systemFontOfSize:12];
	[parent addSubview:l];
	return l;
}
static NSTextField* mkEdit(NSView* parent, CGFloat x, CGFloat y, CGFloat w, BOOL secure) {
	NSTextField* t = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(x,y,w,22)]
	                        : [[NSTextField alloc] initWithFrame:NSMakeRect(x,y,w,22)];
	t.font = [NSFont systemFontOfSize:12];
	[parent addSubview:t];
	return t;
}
static NSButton* mkCheck(NSView* parent, NSString* s, CGFloat x, CGFloat y, CGFloat w) {
	NSButton* b = [NSButton checkboxWithTitle:s target:nil action:nil];
	b.frame = NSMakeRect(x, y, w, 18);
	b.font = [NSFont systemFontOfSize:12];
	[parent addSubview:b];
	return b;
}
static NSButton* mkRadio(NSView* parent, NSString* s, CGFloat x, CGFloat y, CGFloat w) {
	NSButton* b = [NSButton radioButtonWithTitle:s target:nil action:nil];
	b.frame = NSMakeRect(x, y, w, 18);
	b.font = [NSFont systemFontOfSize:12];
	[parent addSubview:b];
	return b;
}
static NSString* sutf8(const char* s) { return [NSString stringWithUTF8String:s ? s : ""]; }

// ───────────────────────── single-profile dialog ───────────────────────────
@interface NppFTPProfileDialog : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate> {
	FTPProfile*   _cur;
	BOOL          _loading;
}
@property (strong) NSWindow* window;
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

- (instancetype)initWithProfile:(FTPProfile*)p { if ((self = [super init])) { _cur = p; } return self; }

// ── build UI ────────────────────────────────────────────────────────────────
- (void)build {
	self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 470)
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
		backing:NSBackingStoreBuffered defer:NO];
	self.window.title = @"Profile settings";
	self.window.releasedWhenClosed = NO;
	self.window.delegate = self;
	NSView* root = self.window.contentView;

	NSTabView* tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(12, 52, 476, 406)];
	[tabs addTabViewItem:[self tabConnection]];
	[tabs addTabViewItem:[self tabAuth]];
	[tabs addTabViewItem:[self tabTransfers]];
	[tabs addTabViewItem:[self tabFTP]];
	[tabs addTabViewItem:[self tabCache]];
	[root addSubview:tabs];

	NSButton* close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeDialog:)];
	close.frame = NSMakeRect(400, 12, 88, 28); close.bezelStyle = NSBezelStyleRounded;
	close.keyEquivalent = @"\r";
	[root addSubview:close];

	[self load];
}

- (NSTabViewItem*)tabConnection {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"conn"]; it.label = @"Connection";
	NSView* v = it.view;
	mkLabel(v, @"Hostname:", 16, 330, 120);
	self.edHost = mkEdit(v, 16, 306, 230, NO); self.edHost.delegate = self;
	mkLabel(v, @"Connection type:", 272, 330, 150);
	self.cbSecurity = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(272, 304, 170, 25)];
	[self.cbSecurity addItemsWithTitles:@[@"FTP", @"FTPES", @"FTPS", @"SFTP"]];
	self.cbSecurity.target = self; self.cbSecurity.action = @selector(securityChanged:);
	[v addSubview:self.cbSecurity];
	mkLabel(v, @"Port:", 16, 280, 120);
	self.edPort = mkEdit(v, 16, 256, 90, NO); self.edPort.delegate = self;
	mkLabel(v, @"Username:", 16, 230, 120);
	self.edUser = mkEdit(v, 16, 206, 230, NO); self.edUser.delegate = self;
	mkLabel(v, @"Password:", 16, 180, 120);
	self.edPass = mkEdit(v, 16, 156, 230, YES); self.edPass.delegate = self;
	self.ckAskPass = mkCheck(v, @"Ask for password", 272, 158, 180); self.ckAskPass.target = self; self.ckAskPass.action = @selector(commit);
	mkLabel(v, @"Timeout (seconds):", 16, 130, 160);
	self.edTimeout = mkEdit(v, 16, 106, 90, NO); self.edTimeout.delegate = self;
	mkLabel(v, @"Initial remote directory:", 16, 80, 200);
	self.edInitDir = mkEdit(v, 16, 56, 426, NO); self.edInitDir.delegate = self;
	mkLabel(v, @"Keep-alive every N seconds (0 = off, server must support NOOP):", 84, 18, 380);
	self.edNoop = mkEdit(v, 16, 14, 60, NO); self.edNoop.delegate = self;
	return it;
}

- (NSTabViewItem*)tabAuth {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"auth"]; it.label = @"Authentication";
	NSView* v = it.view;
	self.ckKey = mkCheck(v, @"Try private key file authentication", 16, 330, 340);
	self.ckPassword = mkCheck(v, @"Try password authentication", 16, 306, 340);
	self.ckInteractive = mkCheck(v, @"Try keyboard interactive authentication", 16, 282, 340);
	for (NSButton* b in @[self.ckKey, self.ckPassword, self.ckInteractive]) { b.target = self; b.action = @selector(commit); }
	mkLabel(v, @"Private key file:", 16, 246, 160);
	self.edKeyFile = mkEdit(v, 16, 222, 396, NO); self.edKeyFile.delegate = self;
	NSButton* kb = [NSButton buttonWithTitle:@"…" target:self action:@selector(browseKeyFile:)];
	kb.frame = NSMakeRect(420, 222, 36, 22); kb.bezelStyle = NSBezelStyleRounded; [v addSubview:kb];
	mkLabel(v, @"Passphrase:", 16, 190, 120);
	self.edPassphrase = mkEdit(v, 16, 166, 290, YES); self.edPassphrase.delegate = self;
	self.ckAskPassphrase = mkCheck(v, @"Ask every time", 314, 168, 150); self.ckAskPassphrase.target = self; self.ckAskPassphrase.action = @selector(commit);
	return it;
}

- (NSTabViewItem*)tabTransfers {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"xfer"]; it.label = @"Transfers";
	NSView* v = it.view;
	NSBox* box1 = [[NSBox alloc] initWithFrame:NSMakeRect(16, 296, 150, 70)]; box1.title = @"Connection mode"; [v addSubview:box1];
	self.rbActive = mkRadio(box1, @"Active", 12, 28, 100); self.rbActive.target = self; self.rbActive.action = @selector(commit);
	self.rbPassive = mkRadio(box1, @"Passive", 12, 6, 100); self.rbPassive.target = self; self.rbPassive.action = @selector(commit);
	NSBox* box2 = [[NSBox alloc] initWithFrame:NSMakeRect(184, 296, 150, 70)]; box2.title = @"Transfer mode"; [v addSubview:box2];
	self.rbAscii = mkRadio(box2, @"ASCII", 12, 28, 100); self.rbAscii.target = self; self.rbAscii.action = @selector(commit);
	self.rbBinary = mkRadio(box2, @"Binary", 12, 6, 100); self.rbBinary.target = self; self.rbBinary.action = @selector(commit);

	mkLabel(v, @"ASCII types:", 16, 270, 120);
	NSScrollView* a = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 150, 210, 116)];
	a.hasVerticalScroller = YES; a.borderType = NSBezelBorder;
	self.asciiList = [[NSTableView alloc] initWithFrame:a.bounds];
	NSTableColumn* ac = [[NSTableColumn alloc] initWithIdentifier:@"a"]; ac.width = 190; [self.asciiList addTableColumn:ac];
	self.asciiList.headerView = nil; self.asciiList.dataSource = self; self.asciiList.delegate = self;
	self.asciiList.target = self; self.asciiList.doubleAction = @selector(removeAscii:);
	a.documentView = self.asciiList; [v addSubview:a];

	mkLabel(v, @"Binary types:", 246, 270, 120);
	NSScrollView* b = [[NSScrollView alloc] initWithFrame:NSMakeRect(246, 150, 210, 116)];
	b.hasVerticalScroller = YES; b.borderType = NSBezelBorder;
	self.binaryList = [[NSTableView alloc] initWithFrame:b.bounds];
	NSTableColumn* bc = [[NSTableColumn alloc] initWithIdentifier:@"b"]; bc.width = 190; [self.binaryList addTableColumn:bc];
	self.binaryList.headerView = nil; self.binaryList.dataSource = self; self.binaryList.delegate = self;
	self.binaryList.target = self; self.binaryList.doubleAction = @selector(removeBinary:);
	b.documentView = self.binaryList; [v addSubview:b];

	mkLabel(v, @"Add ASCII (Enter):", 16, 124, 160);
	self.edAddAscii = mkEdit(v, 16, 100, 210, NO); self.edAddAscii.target = self; self.edAddAscii.action = @selector(addAscii:);
	mkLabel(v, @"Add Binary (Enter):", 246, 124, 160);
	self.edAddBinary = mkEdit(v, 246, 100, 210, NO); self.edAddBinary.target = self; self.edAddBinary.action = @selector(addBinary:);

	NSBox* box3 = [[NSBox alloc] initWithFrame:NSMakeRect(16, 16, 440, 70)]; box3.title = @"Active transfer port range"; [v addSubview:box3];
	mkLabel(box3, @"Min port (>1000):", 12, 14, 120);
	self.edPortMin = mkEdit(box3, 130, 10, 70, NO); self.edPortMin.delegate = self;
	mkLabel(box3, @"Max port (<65000):", 220, 14, 130);
	self.edPortMax = mkEdit(box3, 340, 10, 70, NO); self.edPortMax.delegate = self;
	return it;
}

- (NSTabViewItem*)tabFTP {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"ftp"]; it.label = @"FTP Misc.";
	NSView* v = it.view;
	mkLabel(v, @"LIST parameters:", 16, 330, 160);
	self.edListParams = mkEdit(v, 16, 306, 426, NO); self.edListParams.delegate = self;
	mkLabel(v, @"Hint: try \"-al\" to show hidden files", 16, 286, 400);
	mkLabel(v, @"Groupname:", 16, 250, 200);
	self.edParent = mkEdit(v, 16, 226, 426, NO); self.edParent.delegate = self;
	mkLabel(v, @"Hint: show entry below this submenu", 16, 206, 400);
	return it;
}

- (NSTabViewItem*)tabCache {
	NSTabViewItem* it = [[NSTabViewItem alloc] initWithIdentifier:@"cache"]; it.label = @"Cache";
	NSView* v = it.view;
	mkLabel(v, @"Profile cache maps:", 16, 330, 200);
	NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 168, 350, 156)];
	sc.hasVerticalScroller = YES; sc.borderType = NSBezelBorder;
	self.cacheList = [[NSTableView alloc] initWithFrame:sc.bounds];
	NSTableColumn* lc = [[NSTableColumn alloc] initWithIdentifier:@"local"]; lc.title = @"Local path"; lc.width = 170;
	NSTableColumn* ec = [[NSTableColumn alloc] initWithIdentifier:@"ext"]; ec.title = @"External path"; ec.width = 170;
	[self.cacheList addTableColumn:lc]; [self.cacheList addTableColumn:ec];
	self.cacheList.dataSource = self; self.cacheList.delegate = self;
	sc.documentView = self.cacheList; [v addSubview:sc];

	struct { NSString* t; SEL a; CGFloat y; } cbtns[] = {
		{@"Add new", @selector(cacheAdd:), 290}, {@"Edit", @selector(cacheEdit:), 254}, {@"Delete", @selector(cacheDelete:), 218},
	};
	for (int i = 0; i < 3; i++) {
		NSButton* b = [NSButton buttonWithTitle:cbtns[i].t target:self action:cbtns[i].a];
		b.frame = NSMakeRect(378, cbtns[i].y, 78, 26); b.bezelStyle = NSBezelStyleRounded; [v addSubview:b];
	}

	mkLabel(v, @"Local path:", 16, 138, 100);
	self.edCacheLocal = mkEdit(v, 16, 114, 300, NO);
	NSButton* cb = [NSButton buttonWithTitle:@"…" target:self action:@selector(browseCacheLocal:)];
	cb.frame = NSMakeRect(324, 114, 36, 22); cb.bezelStyle = NSBezelStyleRounded; [v addSubview:cb];
	mkLabel(v, @"External path:", 16, 86, 120);
	self.edCacheExternal = mkEdit(v, 16, 62, 340, NO);
	return it;
}

// ── data sources (ascii / binary / cache lists) ──────────────────────────────
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t {
	if (t == self.asciiList)  return _cur ? _cur->GetAsciiCount() : 0;
	if (t == self.binaryList) return _cur ? _cur->GetBinaryCount() : 0;
	if (t == self.cacheList)  return (_cur && _cur->GetCache()) ? _cur->GetCache()->GetPathMapCount() : 0;
	return 0;
}
- (id)tableView:(NSTableView*)t objectValueForTableColumn:(NSTableColumn*)c row:(NSInteger)r {
	if (!_cur) return @"";
	if (t == self.asciiList)  return sutf8(_cur->GetAsciiType((int)r));
	if (t == self.binaryList) return sutf8(_cur->GetBinaryType((int)r));
	if (t == self.cacheList) {
		const PathMap& pm = _cur->GetCache()->GetPathMap((int)r);
		return [c.identifier isEqual:@"local"] ? sutf8(pm.localpath) : sutf8(pm.externalpath);
	}
	return @"";
}

// ── load / commit ───────────────────────────────────────────────────────────
- (void)load {
	if (!_cur) return;
	_loading = YES;
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
}
- (void)controlTextDidEndEditing:(NSNotification*)n { [self commit]; }
- (void)securityChanged:(id)s {
	int cur = self.edPort.intValue;
	if (cur == 21 || cur == 22 || cur == 0)
		self.edPort.stringValue = (self.cbSecurity.indexOfSelectedItem == Mode_SFTP) ? @"22" : @"21";
	[self commit];
}

// ── ascii/binary type lists ──────────────────────────────────────────────────
- (void)addAscii:(id)s {
	if (!_cur) return;
	NSString* t = self.edAddAscii.stringValue; if (!t.length) return;
	if (![t hasPrefix:@"."]) t = [@"." stringByAppendingString:t];
	_cur->AddAsciiType(t.UTF8String); self.edAddAscii.stringValue = @""; [self.asciiList reloadData];
}
- (void)addBinary:(id)s {
	if (!_cur) return;
	NSString* t = self.edAddBinary.stringValue; if (!t.length) return;
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
	[self commit];
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
	// Show POSIX '/' separators (the Windows default template uses '\'); saving
	// then migrates the stored value to forward slashes.
	self.edCache.stringValue = [sutf8(_settings->GetGlobalCachePath())
	                            stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
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
	[self.window close];
}
- (void)windowWillClose:(NSNotification*)n { if (n.object == self.window) [NSApp stopModal]; }
@end

// ────────────────────────── C++ entry points ───────────────────────────────
// Edit a single profile (no list) — driven from the panel's Create/Edit actions.
extern "C" void NppFTP_ShowProfileSettings(FTPProfile* profile) {
	if (!profile) return;
	@autoreleasepool {
		NppFTPProfileDialog* d = [[NppFTPProfileDialog alloc] initWithProfile:profile];
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
