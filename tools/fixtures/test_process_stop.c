/* Test the exact process-stop bridge, no Swift or MIDI hardware. */
#include "ProcessStop.h"
#include <assert.h>
#include <signal.h>

static volatile sig_atomic_t previous_handler_calls;

static void previous_handler(int sig) {
    (void)sig;
    ++previous_handler_calls;
}

int main(void) {
    struct sigaction custom = {0}, original_int, original_term;
    custom.sa_handler = previous_handler;
    assert(sigemptyset(&custom.sa_mask) == 0);
    assert(sigaction(SIGINT, &custom, &original_int) == 0);
    assert(sigaction(SIGTERM, &custom, &original_term) == 0);
    assert(tihulu_stop_commit() == 0);

    const int signals[] = { SIGINT, SIGTERM };
    for (unsigned i = 0; i < sizeof signals / sizeof signals[0]; ++i) {
        int sig = signals[i];
        /* Stop wins before the terminal commit. */
        assert(tihulu_stop_install() == 0);
        assert(tihulu_stop_install() != 0);
        assert(tihulu_stop_requested() == 0);
        assert(raise(sig) == 0);
        assert(tihulu_stop_requested() == 1);
        assert(tihulu_stop_commit() == 0);
        assert(tihulu_stop_commit() == 0);
        tihulu_stop_restore();
        assert(tihulu_stop_commit() == 0);

        /* New foreground owner: terminal commit wins, late stop does
         * not invalidate an already committed report. */
        assert(tihulu_stop_install() == 0);
        assert(tihulu_stop_requested() == 0);
        assert(tihulu_stop_commit() == 1);
        assert(tihulu_stop_commit() == 0);
        assert(raise(sig) == 0);
        assert(tihulu_stop_requested() == 0);
        tihulu_stop_restore();
        tihulu_stop_restore();

        /* Both previous dispositions must have been restored. */
        sig_atomic_t before = previous_handler_calls;
        assert(raise(SIGINT) == 0);
        assert(raise(SIGTERM) == 0);
        assert(previous_handler_calls == before + 2);
    }
    assert(sigaction(SIGINT, &original_int, 0) == 0);
    assert(sigaction(SIGTERM, &original_term, 0) == 0);
    return 0;
}
