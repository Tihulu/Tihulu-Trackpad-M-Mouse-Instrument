#ifndef TIHULU_PROCESS_STOP_H
#define TIHULU_PROCESS_STOP_H
/* One active owner per foreground process. Install/restore are serialized
 * by the CLI; the request accessor is safe on any thread. */
int tihulu_stop_install(void);
int tihulu_stop_requested(void);
void tihulu_stop_restore(void);
#endif
