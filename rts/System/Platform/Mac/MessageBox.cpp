/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "System/Platform/MessageBox.h"

#if !defined(DEDICATED) && !defined(HEADLESS)
#include <mach-o/dyld.h>   // _NSGetExecutablePath
#include <sys/wait.h>
#include <unistd.h>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#endif

namespace Platform {

#if !defined(DEDICATED) && !defined(HEADLESS)
// Fork+exec a helper and wait. Returns true if it ran and exited != 127
// (127 == exec failed / not found). Kept to fork-then-immediately-exec so it
// is safe even from a half-torn-down process on a fatal path.
static bool runAndWait(const char* path, const std::vector<const char*>& argv)
{
	std::vector<char*> a;
	a.reserve(argv.size() + 1);
	for (const char* s : argv) a.push_back(const_cast<char*>(s));
	a.push_back(nullptr);

	const pid_t pid = fork();
	if (pid < 0)
		return false;
	if (pid == 0) {
		execv(path, a.data());
		_exit(127);
	}
	int status = 0;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
	return WIFEXITED(status) && WEXITSTATUS(status) != 127;
}

static std::string executableDir()
{
	char buf[4096];
	uint32_t sz = sizeof(buf);
	if (_NSGetExecutablePath(buf, &sz) != 0)
		return "";
	const std::string p(buf);
	const auto slash = p.find_last_of('/');
	return (slash == std::string::npos) ? "" : p.substr(0, slash);
}
#endif

/**
 * @brief message box function
 *
 * Surfaces an error to the user instead of the process just vanishing. Prefers
 * the bundled `error-dialog` helper (rich: selectable message + a scrollable
 * this-session log + copy buttons); falls back to `osascript` (always present)
 * so a dev/unbundled build still shows *something*. macOS clone of the
 * Windows MessageBox().
 */
void MsgBox(const char* message, const char* caption, unsigned int flags)
{
#if !defined(DEDICATED) && !defined(HEADLESS)
	const char* msg = (message != nullptr) ? message : "";
	const char* cap = (caption != nullptr) ? caption : "Beyond All Reason";

	// 1) rich bundled helper next to the executable
	const std::string helper = executableDir() + "/error-dialog";
	if (!helper.empty() && access(helper.c_str(), X_OK) == 0) {
		std::vector<const char*> argv = { helper.c_str(), "--title", cap, "--message", msg };
		// BAR_INFOLOG is exported by the launcher; lets the dialog show the
		// full this-session log for a bug report.
		if (const char* infolog = getenv("BAR_INFOLOG")) {
			argv.push_back("--logfile");
			argv.push_back(infolog);
		}
		if (runAndWait(helper.c_str(), argv))
			return;
	}

	// 2) fallback: osascript dialog (escape the AppleScript string literal)
	std::string body(msg);
	std::string esc;
	esc.reserve(body.size() + 16);
	for (const char c : body) {
		if (c == '"' || c == '\\') esc.push_back('\\');
		if (c == '\n') { esc += "\\n"; continue; }
		if (c == '\r') continue;
		esc.push_back(c);
	}
	const std::string script =
		"display dialog \"" + esc + "\" with title \"" + std::string(cap) +
		"\" buttons {\"OK\"} default button 1 with icon stop";
	runAndWait("/usr/bin/osascript",
	           { "/usr/bin/osascript", "-e", script.c_str() });
#else
	(void)message; (void)caption; (void)flags;
#endif
}

}; //namespace Platform
