/*
 * FTPWindow.h — abstract interface to the docked FTP window for the NppFTP
 * macOS port. The Cocoa FTP panel controller implements this; the engine
 * (FTPSession) and the plugin integration (NppFTP) talk to it through here.
 */
#ifndef NPPFTP_FTPWINDOW_H
#define NPPFTP_FTPWINDOW_H

#include "FTPProfile.h"   // vProfile

class FTPSession;
class FTPSettings;
class FileObject;

class FTPWindow {
public:
	virtual ~FTPWindow() {}

	virtual int		Create(void* hParent, void* hNpp, int MenuID, int MenuCommand) = 0;
	virtual int		Destroy() = 0;
	virtual int		Init(FTPSession * session, vProfile * vProfiles, FTPSettings * ftpSettings) = 0;
	virtual int		Show(bool show) = 0;
	virtual int		Focus() = 0;
	virtual bool	IsVisible() = 0;
	virtual void*	GetHWND() = 0;   // the Notifier* used by QueueOperations
	virtual int		OnActivateLocalFile(const char * filename) = 0;
};

#endif // NPPFTP_FTPWINDOW_H
