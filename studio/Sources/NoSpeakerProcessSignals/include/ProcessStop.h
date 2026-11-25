#ifndef TIHULU_PROCESS_STOP_H
#define TIHULU_PROCESS_STOP_H
/* One active owner per foreground process. Install/restore are serialized
 * by the CLI; the request accessor is safe on any thread. */
int tihulu_stop_install(void);
int tihulu_stop_requested(void);
/* Only the serialized owner commits after all children and cleanup exit.
 * Returns 1 if no stop won before this terminal boundary, 0 otherwise.
 * Signals after commitment do not retroactively cancel the report. */
int tihulu_stop_commit(void);
void tihulu_stop_restore(void);
#endif
