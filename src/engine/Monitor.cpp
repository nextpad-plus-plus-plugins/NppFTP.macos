/*
    NppFTP: FTP/SFTP functionality for Notepad++
    Copyright (C) 2010  Harry (harrybharry@users.sourceforge.net)
    macOS port 2026.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version. See <http://www.gnu.org/licenses/>.
*/

#include "StdInc.h"
#include "Monitor.h"

Monitor::Monitor(int nrConditions) :
	m_nrConditions(nrConditions),
	m_enterCount(0)
{
	m_conditions = new AutoResetEvent[m_nrConditions];
}

Monitor::~Monitor() {
	delete [] m_conditions;
}

int Monitor::Enter() {
	m_critMonitor.lock();
	m_enterCount++;
	return 0;
}

int Monitor::Exit() {
	if (m_enterCount > 0) {
		m_enterCount--;
		m_critMonitor.unlock();
	} else {
		return -1;
	}
	return 0;
}

int Monitor::Wait(int condition) {
	//This can cause a deadlock in rare cases. Just dont do an Enter();Signal(); combo
	AutoResetEvent & ev = m_conditions[condition];

	// ResetEvent: clear any pending signal before releasing the monitor.
	{
		std::lock_guard<std::mutex> lk(ev.m);
		ev.signaled = false;
	}

	Exit();

	// WaitForSingleObject(INFINITE) on an auto-reset event: wait until signaled,
	// then consume the signal (auto-reset).
	{
		std::unique_lock<std::mutex> lk(ev.m);
		ev.cv.wait(lk, [&ev]{ return ev.signaled; });
		ev.signaled = false;
	}

	Enter();

	return 0;
}

int Monitor::Signal(int condition) {
	AutoResetEvent & ev = m_conditions[condition];
	{
		std::lock_guard<std::mutex> lk(ev.m);
		ev.signaled = true;
	}
	ev.cv.notify_one();
	return 0;
}
