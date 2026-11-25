#include "ProcessStop.h"
#include <signal.h>
#include <stdatomic.h>
#include <string.h>

/* Do not call Swift, allocate, log, acquire locks or perform MIDI I/O
 * inside a signal handler. Require an always-lock-free atomic. */
#if ATOMIC_INT_LOCK_FREE != 2
#error "Process stop requires an always-lock-free atomic int"
#endif
/* 0: running, 1: stop requested, 2: terminal report committed.
 * The CAS arbitrates the last signal against the success report. */
static atomic_int requested;
static struct sigaction old_int, old_term;
static int installed;

static void stop_handler(int sig) {
    (void)sig;
    int expected = 0;
    (void)atomic_compare_exchange_strong_explicit(&requested, &expected, 1,
                                                 memory_order_relaxed, memory_order_relaxed);
}

int tihulu_stop_install(void) {
    if (installed) return -1;
    atomic_store_explicit(&requested, 0, memory_order_relaxed);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (sigaction(SIGINT, &action, &old_int) != 0) return -1;
    if (sigaction(SIGTERM, &action, &old_term) != 0) {
        (void)sigaction(SIGINT, &old_int, 0);
        return -1;
    }
    installed = 1;
    return 0;
}

int tihulu_stop_requested(void) {
    return atomic_load_explicit(&requested, memory_order_relaxed) == 1;
}

int tihulu_stop_commit(void) {
    int expected = 0;
    if (!installed) return 0;
    return atomic_compare_exchange_strong_explicit(&requested, &expected, 2,
                                                   memory_order_relaxed, memory_order_relaxed);
}

void tihulu_stop_restore(void) {
    if (!installed) return;
    (void)sigaction(SIGTERM, &old_term, 0);
    (void)sigaction(SIGINT, &old_int, 0);
    installed = 0;
}
