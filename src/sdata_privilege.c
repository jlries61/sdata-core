/*
 * Copyright (C) 2026 John L. Ries <john@theyarnbard.com>
 * License: GNU General Public License v3 or later
 * See LICENSE or <https://www.gnu.org/licenses/gpl-3.0.html>
 */

/* Platform-specific privilege detection for SData.
   Returns 1 when the process is running with elevated system-level privilege
   (root on POSIX, SYSTEM account on Windows), 0 otherwise. */

#ifdef _WIN32
#  include <windows.h>
int sdata_is_system_account (void)
{
    HANDLE token;
    TOKEN_ELEVATION elev;
    DWORD size;
    BOOL elevated;

    if (!OpenProcessToken (GetCurrentProcess (), TOKEN_QUERY, &token))
        return 0;
    elevated = GetTokenInformation (token, TokenElevation,
                                    &elev, sizeof (elev), &size)
               && elev.TokenIsElevated;
    CloseHandle (token);
    return elevated ? 1 : 0;
}
#else
#  include <unistd.h>
int sdata_is_system_account (void)
{
    return geteuid () == 0;
}
#endif
