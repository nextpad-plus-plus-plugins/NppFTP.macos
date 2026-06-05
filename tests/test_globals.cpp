/*
 * test_globals.cpp — definitions of the engine's global externs for the
 * headless harness (normally provided by NppFTP.cpp / the plugin). Routes
 * engine output to stderr so the FTP protocol dialog is visible.
 */
#include "StdInc.h"
#include "Output.h"
#include <cstdarg>
#include <string>

class StderrOutput : public Output {
public:
	int OutVA(Output_Type, const TCHAR* message, va_list vaList) override {
		// NppFTP format strings use %T for TCHAR; TCHAR==char here, so %T => %s.
		std::string fmt(message);
		size_t pos = 0;
		while ((pos = fmt.find("%T", pos)) != std::string::npos) { fmt[pos + 1] = 's'; pos += 2; }
		vfprintf(stderr, fmt.c_str(), vaList);
		fprintf(stderr, "\n");
		return 0;
	}
};

static StderrOutput g_stderrOutput;
static char g_configPath[] = "/tmp/nppftp-test";
static char g_hostsFile[]  = "/tmp/nppftp-test/known_hosts";

Output* _MainOutput       = &g_stderrOutput;
HWND    _MainOutputWindow = NULL;
TCHAR*  _ConfigPath       = g_configPath;
char*   _HostsFile        = g_hostsFile;
