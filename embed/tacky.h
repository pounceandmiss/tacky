/*
 * tacky.h - C ABI for driving the tacky XMPP backend as a linked library.
 *
 * The library runs a Tcl interpreter (taco + the tackyd-json JSON contract) on a
 * dedicated backend thread. The host talks to it purely in JSON:
 *
 *   - tacky_send()  feeds a request  ["module","method",{args}]        (or +token)
 *   - the emit callback delivers replies ["result",token,data] /
 *     ["error",token,msg] and events ["event",module,"<Event>",{args}]
 *
 * Threading contract (TDLib-style):
 *   - The emit callback fires on the BACKEND thread, not the caller's. Copy the
 *     bytes out, hand them to your own thread/loop, and return promptly. Do NOT
 *     block inside it and do NOT re-enter tacky (no tacky_send/destroy from it).
 *   - tacky_send() is safe to call from any thread; it queues the request onto
 *     the backend thread and returns immediately.
 *   - Create/destroy should be driven from a single owning thread.
 */
#ifndef TACKY_H
#define TACKY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tacky_client tacky_client;

/* Delivers one JSON message from the backend. `json` is UTF-8, `len` bytes, and
 * is NOT valid after the callback returns - copy what you need. `ud` is the
 * opaque pointer passed to tacky_create(). */
typedef void (*tacky_emit_fn)(void *ud, const char *json, size_t len);

/* Start the backend thread and construct `taco`. `taco_args` is a NULL-
 * terminated array of C strings forwarded to the taco constructor (may be NULL
 * for none). Blocks until the backend is ready. Returns NULL on failure. */
tacky_client *tacky_create(const char *const *taco_args,
                           tacky_emit_fn emit, void *ud);

/* Queue a JSON request onto the backend thread. `json` is UTF-8, `len` bytes;
 * the bytes are copied, so the caller keeps ownership. */
void tacky_send(tacky_client *client, const char *json, size_t len);

/* Tear down: destroy `taco`, stop the backend event loop, join the thread, and
 * free the client. No callbacks fire after this returns. */
void tacky_destroy(tacky_client *client);

#ifdef __cplusplus
}
#endif

#endif /* TACKY_H */
