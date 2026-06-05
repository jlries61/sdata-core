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

/* Signal-mask reset for spawned subprocesses.

   The GNAT runtime blocks most asynchronous signals (SIGALRM, SIGTERM, ...)
   in every task and dispatches them through a dedicated signal-handling task.
   A process forked from such a task inherits that blocked mask across exec,
   so a child like timeout(1) can neither receive SIGALRM (its own deadline)
   nor deliver SIGTERM to the command it wraps -- SYSTEM-command timeouts then
   silently fail to fire.  We clear the calling thread's mask immediately
   before GNAT.OS_Lib.Spawn so the child inherits an empty mask, and restore
   it afterwards.  SYSTEM execution is synchronous, so a single saved-mask
   slot suffices. */

#ifndef _WIN32
#  include <signal.h>
#  include <pthread.h>

static sigset_t sdata_saved_mask;

void sdata_clear_sigmask (void)
{
    sigset_t empty;
    sigemptyset (&empty);
    pthread_sigmask (SIG_SETMASK, &empty, &sdata_saved_mask);
}

void sdata_restore_sigmask (void)
{
    pthread_sigmask (SIG_SETMASK, &sdata_saved_mask, NULL);
}
#else
/* Windows has no POSIX signal mask; these are no-ops. */
void sdata_clear_sigmask (void) { }
void sdata_restore_sigmask (void) { }
#endif
