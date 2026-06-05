/*
	NppFTP: FTP/SFTP functionality for Notepad++
	Copyright (C) 2010  Harry (harrybharry@users.sourceforge.net)
	macOS port 2026.

	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version. See <http://www.gnu.org/licenses/>.
*/

// macOS precompiled-include: the Win32 surface is provided by the compat shim
// instead of winsock2.h/windows.h/tchar.h/uxtheme.h.
#include "win_compat.h"

#include <string>
#include <vector>
#include <deque>
#include <algorithm>

//Library headers
#include "tinyxml.h"

//Common project headers
#include "Output.h"
#include "StringUtils.h"
#include "PathUtils.h"
#include "RefObject.h"

#include "FileObject.h"
