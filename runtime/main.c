/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*-
 * vim: set ts=4 sw=4 et tw=99 ft=cpp:
 */

#include "ejs.h"
#include "ejs-gc.h"
#include "ejs-value.h"
#include "ejs-require.h"
#include "ejs-function.h"
#include "ejs-string.h"
#include "ejs-runloop.h"

#define GC_ON_SHUTDOWN 0

extern EJSModule* entry_module;

#include <signal.h>
#include <setjmp.h>
#include <unistd.h>
#include <execinfo.h>

sigjmp_buf segvbuf;

static void
segv_handler(int signum)
{
    siglongjmp (segvbuf, 1);
}

static void backtrace_and_exit(int sig) {
    static void *array[10];
    size_t size;

    size = backtrace(array, 10);
    fprintf(stderr, "Error: signal %d:\n", sig);
    backtrace_symbols_fd(array, size, STDERR_FILENO);
    exit(1);
}


int
main(int argc, char** argv)
{
    if (getenv ("EJS_WAIT_ON_SEGV")) {
        if (sigsetjmp(segvbuf, 1)) {
            printf ("attach to pid %d\n", getpid());
            while (1) sleep (100);
            abort();
        }

        signal (SIGSEGV, segv_handler);
    } else {
        signal (SIGSEGV, backtrace_and_exit);
    }

    EJS_GC_MARK_THREAD_STACK_BOTTOM;

    _ejs_init(argc, argv);

    _ejs_module_resolve (entry_module);

    _ejs_runloop_start();

#if GC_ON_SHUTDOWN
    _ejs_gc_shutdown();
#endif
    return 0;
}
