/*
 * test_engine.cpp — headless validation harness for the NppFTP engine.
 *
 * Drives the FTP/FTPS/SFTP client wrappers directly (no UI), exercising
 * connect, PWD, directory listing (the LIST parser), and download against a
 * real server. Usage:
 *   test_engine <ftp|ftpes|ftps|sftp> <host> <port> <user> <pass> [path]
 * Defaults to the Rebex public test server when no args are given.
 */
#include "StdInc.h"
#include "FTPClientWrapper.h"
#include "FTPSettings.h"
#include "UIProvider.h"
#include <cstdio>
#include <cstring>
#include <string>

// Non-interactive UI provider: no password prompts, auto-accept certs/hosts.
class StubUI : public UIProvider {
public:
	int PromptInput(void*, const char*, const char*, const char*, bool, std::string&) override { return 2; }
	int PromptKBInt(void*, ssh_session) override { return 0; }
	int MessageBox(void*, const char* text, const char*, unsigned) override {
		fprintf(stderr, "[MessageBox] %s -> (auto IDYES)\n", text ? text : "");
		return IDYES; // accept unknown certs/known-hosts for testing
	}
};

static const char* typeStr(FTPFileType t) {
	switch (t) {
		case FTPTypeDir:  return "DIR ";
		case FTPTypeLink: return "LINK";
		default:          return "file";
	}
}

int main(int argc, char** argv) {
	static StubUI ui; SetUIProvider(&ui);
	FTPSettings::SetDebugMode(true);   // show the protocol trace

	const char* mode = (argc > 1) ? argv[1] : "sftp";
	const char* host = (argc > 2) ? argv[2] : "test.rebex.net";
	int         port = (argc > 3) ? atoi(argv[3]) : (strcmp(mode, "sftp") == 0 ? 22 : 21);
	const char* user = (argc > 4) ? argv[4] : "demo";
	const char* pass = (argc > 5) ? argv[5] : "password";
	const char* path = (argc > 6) ? argv[6] : "/";

	printf("== NppFTP engine test: %s %s:%d user=%s ==\n", mode, host, port, user);

	FTPClientWrapper* w = nullptr;
	if (strcmp(mode, "sftp") == 0) {
		FTPClientWrapperSSH* s = new FTPClientWrapperSSH(host, port, user, pass);
		w = s;
	} else {
		FTPClientWrapperSSL* s = new FTPClientWrapperSSL(host, port, user, pass);
		if      (strcmp(mode, "ftps")  == 0) s->SetMode(CUT_FTPClient::FTPS);
		else if (strcmp(mode, "ftpes") == 0) s->SetMode(CUT_FTPClient::FTPES);
		else                                  s->SetMode(CUT_FTPClient::FTP);
		s->SetConnectionMode(Mode_Passive);
		s->SetListParams("");
		static vX509 g_certs;          // trusted-cert store (empty; unknown certs prompt)
		s->SetCertificates(&g_certs);
		w = s;
	}
	w->SetTimeout(20);

	int r = w->Connect();
	printf("Connect() = %d\n", r);
	if (r != 0) { printf("CONNECT FAILED\n"); return 1; }

	char pwd[1024] = {0};
	if (w->Pwd(pwd, sizeof(pwd)) == 0) printf("PWD = %s\n", pwd);

	FTPFile* files = nullptr;
	int count = w->GetDir(path, &files);
	printf("GetDir(%s) = %d entries\n", path, count);
	for (int i = 0; i < count; i++) {
		printf("  [%s] %-40s %10ld  %s\n", typeStr(files[i].fileType),
		       files[i].filePath, files[i].fileSize, files[i].mod);
	}
	// Download the first regular file found, to validate RETR / ReceiveFile.
	for (int i = 0; i < count; i++) {
		if (files[i].fileType == FTPTypeFile && files[i].fileSize > 0) {
			const char* local = "/tmp/nppftp_dl.bin";
			int dr = w->ReceiveFile(local, files[i].filePath);
			struct stat st; long got = (stat(local, &st) == 0) ? (long)st.st_size : -1;
			printf("ReceiveFile(%s) = %d, downloaded %ld bytes (expected %ld)\n",
			       files[i].filePath, dr, got, files[i].fileSize);
			break;
		}
	}
	if (files) FTPClientWrapper::ReleaseDir(files, count);

	w->Disconnect();
	delete w;
	printf("== done ==\n");
	return 0;
}
