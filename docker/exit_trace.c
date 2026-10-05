// LD_PRELOAD shim for DockerDev.sh (DEBUG=1): prints a stack trace to stderr when the
// process terminates through exit()/_exit()/_Exit() with a non-zero status or on a fatal
// signal. Used instead of gdb because the network plugin traps when a debugger is attached.
// Resolve addresses with: addr2line -Cfe build_docker/src/bambu-studio <addr>
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void dump_stack(const char *why, int code)
{
    void *frames[128];
    int   n = backtrace(frames, 128);
    dprintf(2, "\n==== exit_trace: %s (%d), %d frames ====\n", why, code, n);
    backtrace_symbols_fd(frames, n, 2);
    dprintf(2, "==== exit_trace end ====\n");
}

void exit(int status)
{
    static void (*real_exit)(int) __attribute__((noreturn));
    if (!real_exit) real_exit = dlsym(RTLD_NEXT, "exit");
    if (status != 0) dump_stack("exit", status);
    real_exit(status);
}

void _exit(int status)
{
    static void (*real__exit)(int) __attribute__((noreturn));
    if (!real__exit) real__exit = dlsym(RTLD_NEXT, "_exit");
    if (status != 0) dump_stack("_exit", status);
    real__exit(status);
}

void _Exit(int status) { _exit(status); }

static void on_fatal_signal(int sig)
{
    dump_stack(strsignal(sig), sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor)) static void install_handlers(void)
{
    const int sigs[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL};
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); ++i) signal(sigs[i], on_fatal_signal);
}
