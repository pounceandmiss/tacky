/*
 * tacky.c - libtacky shim: runs the tacky/taco Tcl backend on a private thread
 * and exposes the JSON contract over a small C ABI (see tacky.h).
 *
 * Layout of the two threads:
 *   - caller thread: tacky_create / tacky_send / tacky_destroy
 *   - backend thread: owns the Tcl_Interp, runs the event loop, and is the only
 *     thread that ever touches the interpreter. Requests cross over as queued
 *     Tcl_Events (Tcl_ThreadQueueEvent); replies/events cross back out through
 *     the emit callback, which therefore fires on THIS backend thread.
 *
 * The Tcl side is the same tackyd-json JSON contract the tackyd-json daemon
 * speaks; bin/tackyd-embed.tcl just swaps the transport ends: it calls the C
 * command `tacky_native_emit {json}` to emit, and is fed requests by our
 * calling `tackyd_dispatch {json}`.
 */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <tcl.h>

#include "tacky.h"
#include "static_pkgs.h"

/* The bundled script tree, parked in .rodata by the `lib` build target
 * (ld -r -b binary scripts.zip + objcopy). Mounted read-only, no copy. */
extern const unsigned char _binary_scripts_zip_start[];
extern const unsigned char _binary_scripts_zip_end[];

struct tacky {
    Tcl_ThreadId  tid;      /* backend thread */
    Tcl_Interp   *interp;   /* backend-thread-owned */
    tacky_emit_fn emit;
    void         *ud;
    char        **args;     /* NULL-terminated copy of taco_args */

    /* create()/teardown handshake (lock+cond guard ready/rc, then done) */
    Tcl_Mutex     lock;
    Tcl_Condition cond;
    int           ready;    /* backend has finished init (ok or fail) */
    int           rc;       /* TCL_OK / TCL_ERROR from init */

    int           stop;     /* backend-only: set by the stop event */
    int           done;     /* backend loop exited + interp deleted; safe to free */
};

/* ---- events crossing into the backend thread ---- */

typedef struct {
    Tcl_Event     header;
    tacky *t;
    size_t        len;
    char          json[1];  /* flexible; allocated with len+1 trailing bytes */
} DispatchEvent;

typedef struct {
    Tcl_Event     header;
    tacky *t;
} StopEvent;

static int DispatchEventProc(Tcl_Event *evPtr, int flags) {
    (void)flags;
    DispatchEvent *ev = (DispatchEvent *)evPtr;
    Tcl_Interp *interp = ev->t->interp;
    Tcl_Obj *objv[2];

    objv[0] = Tcl_NewStringObj("tackyd_dispatch", -1);
    objv[1] = Tcl_NewStringObj(ev->json, (Tcl_Size)ev->len);
    Tcl_IncrRefCount(objv[0]);
    Tcl_IncrRefCount(objv[1]);
    if (Tcl_EvalObjv(interp, 2, objv, TCL_EVAL_GLOBAL) != TCL_OK) {
        /* A malformed request must not kill the loop - route to bgerror. */
        Tcl_BackgroundException(interp, TCL_ERROR);
    }
    Tcl_DecrRefCount(objv[0]);
    Tcl_DecrRefCount(objv[1]);
    return 1;  /* handled; the notifier frees evPtr */
}

static int StopEventProc(Tcl_Event *evPtr, int flags) {
    (void)flags;
    StopEvent *ev = (StopEvent *)evPtr;
    Tcl_Eval(ev->t->interp, "catch {taco destroy}");
    ev->t->stop = 1;
    return 1;
}

/* ---- the C command the Tcl side calls to emit a message out ---- */

static int EmitCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    tacky *c = (tacky *)cd;
    Tcl_Size len;
    const char *s;

    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "json");
        return TCL_ERROR;
    }
    s = Tcl_GetStringFromObj(objv[1], &len);
    if (c->emit) {
        c->emit(c->ud, s, (size_t)len);
    }
    return TCL_OK;
}

/* ---- backend thread ---- */

static int fail(Tcl_Interp *interp, const char *stage) {
    fprintf(stderr, "tacky: %s failed: %s\n", stage, Tcl_GetStringResult(interp));
    return TCL_ERROR;
}

/* Process-global guard for the shared //zipfs:/app mount (see BackendInit).
 * A static Tcl_Mutex is self-initialising on first Tcl_MutexLock. */
static Tcl_Mutex g_mount_lock;
static int       g_mounted = 0;

/* Bring up the interpreter and construct taco. Returns TCL_OK on success. */
static int BackendInit(tacky *c) {
    Tcl_Interp *interp = Tcl_CreateInterp();
    size_t ziplen = (size_t)(_binary_scripts_zip_end - _binary_scripts_zip_start);
    Tcl_Obj **objv;
    Tcl_Size n, i, rc;

    c->interp = interp;
    /* NULL, not `interp`: a non-NULL interp makes Tcl_StaticLibrary run every
     * init proc immediately (before Tcl_Init/mount). NULL registers them
     * process-globally and lazily, so `load {} <Name>` resolves on demand -
     * matching how the kitsh launcher registers them. */
    Zippy_RegisterStaticPackages(NULL);

    /* Mount the script tree before Tcl_Init so init.tcl loads from the zip.
     * The zipfs mount is process-global (shared across interps), not per-interp,
     * so mount exactly once: a second tacky_create in the same process (restart,
     * or more than one instance) would otherwise fail with "already mounted". The
     * guard is under a global mutex; the mount outlives any single interp. */
    Tcl_MutexLock(&g_mount_lock);
    if (!g_mounted) {
        if (TclZipfs_MountBuffer(interp, _binary_scripts_zip_start, ziplen,
                                 "//zipfs:/app", 0) != TCL_OK) {
            Tcl_MutexUnlock(&g_mount_lock);
            return fail(interp, "TclZipfs_MountBuffer");
        }
        g_mounted = 1;
    }
    Tcl_MutexUnlock(&g_mount_lock);
    Tcl_SetVar2Ex(interp, "tcl_library", NULL,
                  Tcl_NewStringObj("//zipfs:/app/tcl_library", -1), TCL_GLOBAL_ONLY);
    if (Tcl_Init(interp) != TCL_OK) {
        return fail(interp, "Tcl_Init");
    }

    /* Must exist before taco is constructed: the constructor may emit for
     * already-known accounts, and `tacky emit` funnels through this command. */
    Tcl_CreateObjCommand(interp, "tacky_native_emit", EmitCmd, c, NULL);

    if (Tcl_EvalFile(interp, "//zipfs:/app/bin/tackyd-embed.tcl") != TCL_OK) {
        return fail(interp, "source tackyd-embed.tcl");
    }

    /* tackyd_embed_init {*}$args  -> taco_type create taco {*}$args */
    for (n = 0; c->args && c->args[n]; n++) { /* count */ }
    objv = (Tcl_Obj **)Tcl_Alloc(sizeof(Tcl_Obj *) * (size_t)(n + 1));
    objv[0] = Tcl_NewStringObj("tackyd_embed_init", -1);
    for (i = 0; i < n; i++) {
        objv[i + 1] = Tcl_NewStringObj(c->args[i], -1);
    }
    for (i = 0; i <= n; i++) { Tcl_IncrRefCount(objv[i]); }
    rc = Tcl_EvalObjv(interp, n + 1, objv, TCL_EVAL_GLOBAL);
    for (i = 0; i <= n; i++) { Tcl_DecrRefCount(objv[i]); }
    Tcl_Free((char *)objv);

    return (rc == TCL_OK) ? TCL_OK : fail(interp, "tackyd_embed_init");
}

static Tcl_ThreadCreateType BackendThreadProc(void *cd) {
    tacky *c = (tacky *)cd;
    int rc = BackendInit(c);

    Tcl_MutexLock(&c->lock);
    c->rc = rc;
    c->ready = 1;
    Tcl_ConditionNotify(&c->cond);
    Tcl_MutexUnlock(&c->lock);

    if (rc == TCL_OK) {
        while (!c->stop) {
            Tcl_DoOneEvent(TCL_ALL_EVENTS);
        }
    }
    if (c->interp) {
        Tcl_DeleteInterp(c->interp);
        c->interp = NULL;
    }

    /* Final act: report completion so the reaper (tacky_destroy / a failed
     * tacky_create) can release *c. Raised under the lock, like ready, so once
     * the reaper observes done and re-acquires the lock it knows this thread has
     * stopped touching *c and the lock/cond - the detached-thread stand-in for a
     * join. After the unlock below nothing here dereferences *c again. */
    Tcl_MutexLock(&c->lock);
    c->done = 1;
    Tcl_ConditionNotify(&c->cond);
    Tcl_MutexUnlock(&c->lock);

    /* Release this thread's Tcl thread-specific data (notifier registration,
     * encodings, ...) before it exits. Without this, each create/destroy cycle
     * leaks per-thread notifier state and, after a few cycles, a fresh backend
     * thread's Tcl_DoOneEvent stops servicing queued events (replies never fire).
     * Must be the last Tcl call on this thread; it touches only this thread's
     * data, not *c, so it is safe even if reap() has already freed the handle. */
    Tcl_FinalizeThread();
    TCL_THREAD_CREATE_RETURN;
}

/* ---- public ABI ---- */

static void free_args(char **args) {
    if (!args) return;
    for (size_t i = 0; args[i]; i++) free(args[i]);
    free(args);
}

/* Reclaim *c once the backend thread is finished with it - the replacement for
 * Tcl_JoinThread (whose thread-handle wait wedged under wine). The backend
 * raises c->done under c->lock as its last act; observing it under the lock
 * guarantees the thread has stopped touching *c and the lock/cond, so we can
 * finalize and free them. The thread is detached, so there is no handle to
 * join - the OS reaps it on return. Bounded wait: if the backend never reports
 * done (a wedged interp), leak *c rather than free it under a live thread. */
static void reap(tacky *c) {
    int done, waited_ms = 0;

    Tcl_MutexLock(&c->lock);
    while (!c->done && waited_ms < 2000) {
        Tcl_Time t = { 0, 100000 };   /* wait in 100 ms slices */
        Tcl_ConditionWait(&c->cond, &c->lock, &t);
        waited_ms += 100;
    }
    done = c->done;
    Tcl_MutexUnlock(&c->lock);

    if (!done) return;   /* backend still running; leaking beats a use-after-free */

    Tcl_MutexFinalize(&c->lock);
    Tcl_ConditionFinalize(&c->cond);
    free_args(c->args);
    free(c);
}

tacky *tacky_create(const char *const *taco_args,
                           tacky_emit_fn emit, void *ud) {
    tacky *c;
    size_t n = 0, i;

    /* Initialise the Tcl library (notifier, threads, encodings) before the
     * first Tcl_CreateThread / mutex call. Idempotent; safe to repeat. */
    Tcl_FindExecutable(NULL);

    c = (tacky *)calloc(1, sizeof *c);
    if (!c) return NULL;
    c->emit = emit;
    c->ud = ud;

    if (taco_args) { while (taco_args[n]) n++; }
    c->args = (char **)calloc(n + 1, sizeof(char *));
    if (!c->args) { free(c); return NULL; }
    for (i = 0; i < n; i++) {
        c->args[i] = strdup(taco_args[i]);
        if (!c->args[i]) { free_args(c->args); free(c); return NULL; }
    }

    /* Detached (NOFLAGS), not joinable: teardown synchronises on c->done via
     * reap() instead of Tcl_JoinThread, so nothing waits on the thread handle. */
    if (Tcl_CreateThread(&c->tid, BackendThreadProc, c,
                         TCL_THREAD_STACK_DEFAULT, TCL_THREAD_NOFLAGS) != TCL_OK) {
        free_args(c->args); free(c);
        return NULL;
    }

    Tcl_MutexLock(&c->lock);
    while (!c->ready) { Tcl_ConditionWait(&c->cond, &c->lock, NULL); }
    Tcl_MutexUnlock(&c->lock);

    if (c->rc != TCL_OK) {
        /* Init failed; the backend tears its interp down and reports done. */
        reap(c);
        return NULL;
    }
    return c;
}

void tacky_send(tacky *c, const char *json, size_t len) {
    DispatchEvent *ev;
    if (!c) return;

    ev = (DispatchEvent *)Tcl_Alloc(offsetof(DispatchEvent, json) + len + 1);
    ev->header.proc = DispatchEventProc;
    ev->header.nextPtr = NULL;
    ev->t = c;
    ev->len = len;
    memcpy(ev->json, json, len);
    ev->json[len] = '\0';

    Tcl_ThreadQueueEvent(c->tid, (Tcl_Event *)ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(c->tid);
}

void tacky_destroy(tacky *c) {
    StopEvent *ev;
    if (!c) return;

    ev = (StopEvent *)Tcl_Alloc(sizeof *ev);
    ev->header.proc = StopEventProc;
    ev->header.nextPtr = NULL;
    ev->t = c;
    Tcl_ThreadQueueEvent(c->tid, (Tcl_Event *)ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(c->tid);

    /* Wait for the backend to run the stop event, delete its interp and report
     * done, then finalize and free *c. Replaces Tcl_JoinThread. */
    reap(c);
}
