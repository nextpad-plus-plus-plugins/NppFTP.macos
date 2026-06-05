/*
 * test_profiles.cpp — headless coverage for the profile lifecycle that caused
 * the in-app crashes: refcount ownership (create vs load vs connect/disconnect
 * vs delete) and Save/Load round-trips incl. folder dummies + empty fields.
 * Builds profiles via the engine API (no hand-written XML), then save->load.
 */
#include "StdInc.h"
#include "FTPProfile.h"
#include "FTPCache.h"
#include "FTPSettings.h"
#include "FTPSession.h"
#include "Encryption.h"
#include "tinyxml.h"
#include <cstdio>
#include <string>

static int g_fail = 0;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); g_fail++; } else printf("ok  : %s\n", msg); } while (0)

static FTPSettings* g_settings = NULL;

// Mirror the app's "create" path: new + cache parent + AddRef (list owns ref 1).
static FTPProfile* makeProfile(const char* name, const char* parent, const char* host) {
	FTPProfile* p = new FTPProfile(name);
	p->SetCacheParent(g_settings->GetGlobalCache());
	p->SetParent(parent);
	if (host) p->SetHostname(host);
	p->AddRef();
	return p;
}

static std::string saveTo(const vProfile& profiles) {
	TiXmlElement* pe = FTPProfile::SaveProfiles(profiles);
	TiXmlPrinter pr; pe->Accept(&pr);
	std::string s = pr.CStr();
	delete pe;
	return s;
}
static vProfile loadFrom(const std::string& profilesXml) {
	std::string doc = std::string("<NppFTP>") + profilesXml + "</NppFTP>";
	TiXmlDocument d; d.Parse(doc.c_str());
	const TiXmlElement* root = d.RootElement();
	const TiXmlElement* pe = root ? root->FirstChildElement("Profiles") : NULL;
	return pe ? FTPProfile::LoadProfiles(pe) : vProfile();
}
static FTPProfile* findByName(const vProfile& v, const char* name) {
	for (FTPProfile* p : v) if (std::string(p->GetName() ? p->GetName() : "") == name) return p;
	return NULL;
}

int main() {
	Encryption::Init();
	FTPSettings settings; g_settings = &settings;

	// ── build a set of profiles incl. a folder + an empty-name folder dummy ──
	vProfile profs;
	profs.push_back(makeProfile("srvA", "", "a.example"));       // top-level
	profs.push_back(makeProfile("srvB", "/Work", "b.example"));  // inside folder /Work
	profs.push_back(makeProfile("", "/Empty", ""));              // empty folder dummy

	CHECK(profs.size() == 3, "create: 3 profiles built");
	CHECK(profs[0]->AddRef() == 2 && profs[0]->Release() == 1, "create: each profile owned at refcount 1");

	// ── round-trip: save -> load (loaded profiles must also be refcount 1) ──
	std::string xml = saveTo(profs);
	CHECK(xml.find("name=\"srvA\"") != std::string::npos, "save: serialises without crashing");
	CHECK(xml.find("parent=\"/Empty\"") != std::string::npos, "save: empty-name folder dummy keeps its parent path");

	vProfile loaded = loadFrom(xml);
	CHECK(loaded.size() == 3, "load: 3 profiles back");
	FTPProfile* lA = findByName(loaded, "srvA");
	CHECK(lA && std::string(lA->GetHostname()) == "a.example", "round-trip: fields preserved (hostname)");
	CHECK(lA && lA->AddRef() == 2 && lA->Release() == 1, "load: loaded profile owned at refcount 1 (the fix)");
	FTPProfile* lEmpty = findByName(loaded, "");
	CHECK(lEmpty && std::string(lEmpty->GetParent()) == "/Empty", "round-trip: folder dummy parent preserved");

	// ── THE CRASH SCENARIO: connect + failed-connect teardown on a LOADED profile
	//    must NOT free it while still in the list, then SAVE. StartSession does
	//    m_currentProfile->AddRef() and TerminateSession does Release() — replay
	//    exactly that refcount sequence (no worker threads needed). ──
	int rcAfterConnect = lA->AddRef();     // StartSession: 1 -> 2
	int rcAfterDisc    = lA->Release();    // TerminateSession: 2 -> 1 (must NOT free)
	CHECK(rcAfterConnect == 2 && rcAfterDisc == 1, "connect(AddRef)+disconnect(Release) keeps loaded profile at refcount 1");
	CHECK(std::string(lA->GetHostname()) == "a.example", "connect+disconnect leaves loaded profile alive (no UAF)");

	std::string xml2 = saveTo(loaded);     // the rename-after-failed-connect save path
	CHECK(xml2.find("name=\"srvA\"") != std::string::npos, "save after connect/disconnect: no dangling-pointer crash");

	// ── rename a loaded profile, then save (exact repro of the reported crash) ──
	lA->SetName("renamedA");
	std::string xml3 = saveTo(loaded);
	CHECK(xml3.find("name=\"renamedA\"") != std::string::npos, "rename loaded profile + save: works");

	// ── delete: erase + Release frees it exactly once. (Release returns the count
	//    BEFORE self-delete would be UB to read, so verify the count is 1 first.) ──
	FTPProfile* lB = findByName(loaded, "srvB");
	size_t before = loaded.size();
	int lbRef = lB->AddRef(); lB->Release();           // peek: 1 -> 2 -> 1
	CHECK(lbRef == 2, "delete: loaded profile is at refcount 1 before delete");
	for (size_t i = 0; i < loaded.size(); i++) if (loaded[i] == lB) { loaded.erase(loaded.begin()+i); break; }
	lB->Release();                                      // 1 -> 0 -> freed (no underflow)
	CHECK(loaded.size() == before - 1, "delete: profile removed from the list");

	// ── connect then delete (refcounts stay sane) ──
	lA->AddRef(); lA->Release();                        // connect/disconnect: 1->2->1
	int laRef = lA->AddRef(); lA->Release();            // peek: still 1
	CHECK(laRef == 2, "connect/disconnect leaves the profile at refcount 1 (delete will free once)");
	for (size_t i = 0; i < loaded.size(); i++) if (loaded[i] == lA) { loaded.erase(loaded.begin()+i); break; }
	lA->Release();                                      // freed once

	// cleanup
	for (FTPProfile* p : profs)  p->Release();
	for (FTPProfile* p : loaded) p->Release();

	printf(g_fail ? "\n%d FAILURE(S)\n" : "\nALL PASS\n", g_fail);
	return g_fail ? 1 : 0;
}
