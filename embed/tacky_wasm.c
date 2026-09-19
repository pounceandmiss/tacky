/*
 * tacky_wasm.c - libtacky shim for the browser: tacky.c's JSON contract
 * (tackyd-embed.tcl, tacky_native_emit out, tackyd_dispatch in) on a Worker's
 * single thread.
 *
 * `vwait ::forever` stays on the stack; zippy's Emscripten notifier
 * (tclemnotify.c) waits with emscripten_sleep and Asyncify unwinds to let
 * JavaScript run. A ccall into a suspended interpreter silently does
 * nothing, so requests are pulled: they wait in globalThis.tackyInbox and
 * the pump the notifier runs between waits drains them, queueing each as a
 * Tcl event (Tcl_DoOneEvent in blocking mode returns only once it has
 * processed one). One postMessage is one JSON message; no framing here.
 *
 * The globals and entry points below are the contract with wasm/src/worker.js.
 */
#include <emscripten.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tcl.h>

#include "tacky_interp.h"
#include "tclemnotify.h"
#include "opfsvfs.h"
#include "wschan.h"
#include "httpx.h"

/* The bundled script tree, a C array in .rodata (zippy/emscripten/blob2c.tcl:
 * no _end symbol on this target, a length instead). */
extern const unsigned char _binary_scripts_zip_start[];
extern const unsigned long _binary_scripts_zip_len;

static Tcl_Interp *interp = NULL;

/* ---- the JavaScript side ---- */

/* One queued request, or NULL when the inbox is empty. The caller frees. */
EM_JS(char *, tacky_take_request, (void), {
    const q = globalThis.tackyInbox;
    if (!q || q.length === 0) {
        return 0;
    }
    return stringToNewUTF8(q.shift());
});

/* Has the page asked us to stop? Pulled and cleared, like the requests. */
EM_JS(int, tacky_take_stop, (void), {
    if (!globalThis.tackyStopRequested) {
        return 0;
    }
    globalThis.tackyStopRequested = false;
    return 1;
});

/* One message from the backend to the page. */
EM_JS(void, tacky_post, (const char *json), {
    globalThis.tackyOutbox(UTF8ToString(json));
});

/* Out-of-band notes: boot progress, and anything fatal. */
EM_JS(void, tacky_report, (const char *line), {
    const s = UTF8ToString(line);
    if (typeof globalThis.tackyReport === 'function') {
        globalThis.tackyReport(s);
    } else {
        console.log(s);
    }
});

/*
 * Write an IDBFS mount back to IndexedDB (the storage fallback; OPFS is
 * durable per commit). EM_ASYNC_JS so the interpreter is stopped while it
 * runs: called from a Tcl timer, no SQLite operation is in flight, and IDBFS
 * copies whole files, so a mid-transaction snapshot could pair a database
 * with the wrong WAL.
 */
EM_ASYNC_JS(int, tacky_syncfs, (void), {
    return await new Promise((resolve) => {
        FS.syncfs(false, (err) => {
            if (err) console.error('tacky: could not persist the store:', err);
            resolve(err ? 1 : 0);
        });
    });
});

static void
report(const char *fmt, ...)
{
    char buf[2048];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    tacky_report(buf);
}

/* ---- Tcl -> the page ---- */

/* `tacky_native_emit {json}`, the sink bin/tackyd-embed.tcl installs. */
static int
EmitCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "json");
        return TCL_ERROR;
    }
    tacky_post(Tcl_GetString(objv[1]));
    return TCL_OK;
}

/* `tacky_sync`, for the persistence loop. Errors are reported, not raised:
 * a browser that will not store is degraded, not broken. */
static int
SyncCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    (void)cd;
    if (objc != 1) {
        Tcl_WrongNumArgs(ip, 1, objv, "");
        return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(tacky_syncfs() == 0));
    return TCL_OK;
}

/* ---- the page -> Tcl ---- */

typedef struct {
    Tcl_Event header;
    char     *json;   /* Tcl_Alloc'd; NULL for a stop */
    Tcl_Size  len;
} DispatchEvent;

/* What the worker asks for when the page is going away. */
static const char STOP_SCRIPT[] =
    "catch {taco destroy}\n"
    "set ::forever stopped";

static int
DispatchProc(Tcl_Event *evPtr, int flags)
{
    DispatchEvent *ev = (DispatchEvent *)evPtr;
    Tcl_Obj *objv[2];

    if (!(flags & TCL_ALL_EVENTS)) {
        return 0; /* not now; Tcl offers it again */
    }
    if (ev->json == NULL) {
        if (Tcl_Eval(interp, STOP_SCRIPT) != TCL_OK) {
            Tcl_BackgroundException(interp, TCL_ERROR);
        }
        return 1;
    }
    objv[0] = Tcl_NewStringObj("tackyd_dispatch", -1);
    objv[1] = Tcl_NewStringObj(ev->json, ev->len);
    Tcl_IncrRefCount(objv[0]);
    Tcl_IncrRefCount(objv[1]);
    /* A malformed request goes to bgerror; the loop goes on. */
    if (Tcl_EvalObjv(interp, 2, objv, TCL_EVAL_GLOBAL) != TCL_OK) {
        Tcl_BackgroundException(interp, TCL_ERROR);
    }
    Tcl_DecrRefCount(objv[0]);
    Tcl_DecrRefCount(objv[1]);
    Tcl_Free(ev->json);
    return 1;
}

/* `json` NULL queues the stop instead of a request. */
static void
queueDispatch(char *json, size_t len)
{
    DispatchEvent *ev = (DispatchEvent *)Tcl_Alloc(sizeof *ev);

    ev->header.proc = DispatchProc;
    ev->header.nextPtr = NULL;
    ev->json = json;
    ev->len = (Tcl_Size)len;
    Tcl_QueueEvent(&ev->header, TCL_QUEUE_TAIL);
}

/* Drain the inbox. Runs from the notifier, between waits. */
static void
Pump(void *cd)
{
    char *json;

    (void)cd;
    while ((json = tacky_take_request()) != NULL) {
        size_t len = strlen(json);
        char *copy = Tcl_Alloc(len + 1);

        memcpy(copy, json, len + 1);
        free(json); /* stringToNewUTF8 mallocs on the wasm heap */
        queueDispatch(copy, len);
    }
    if (tacky_take_stop()) {
        queueDispatch(NULL, 0);
    }
}

/* ---- the entry points the worker calls ---- */

/* Bring the interpreter up as far as the embed script; tacky_start creates taco. */
EMSCRIPTEN_KEEPALIVE
int
tacky_boot(void)
{
    const char *stage = "";

    if (interp != NULL) {
        return 0;
    }
    TclEm_InstallNotifier();
    Tcl_FindExecutable("/tacky");
    interp = Tcl_CreateInterp();
    if (interp == NULL) {
        report("FAIL no interpreter");
        return 1;
    }
    Tcl_CreateObjCommand(interp, "tacky_sync", SyncCmd, NULL, NULL);
    if (TackyInterpInit(interp, _binary_scripts_zip_start, _binary_scripts_zip_len,
                        EmitCmd, NULL, &stage) != TCL_OK) {
        report("FAIL %s: %s", stage, Tcl_GetStringResult(interp));
        return 1;
    }
    /* The Tcl side of opfsvfs; the VFS itself is registered from the worker. */
    if (Opfsvfs_Init(interp) != TCL_OK) {
        report("FAIL opfsvfs: %s", Tcl_GetStringResult(interp));
        return 1;
    }
    /* ::wschan: -transport websocket. */
    if (Wschan_Init(interp) != TCL_OK) {
        report("FAIL wschan: %s", Tcl_GetStringResult(interp));
        return 1;
    }
    /* ::httpx: file transfers over the browser's HTTP stack (taco_http). */
    if (Httpx_Init(interp) != TCL_OK) {
        report("FAIL httpx: %s", Tcl_GetStringResult(interp));
        return 1;
    }
    TclEm_SetPump(Pump, NULL);
    report("ok boot %s", Tcl_GetVar2(interp, "tcl_patchLevel", NULL, TCL_GLOBAL_ONLY));
    return 0;
}

/*
 * Create the backend. `args` is a Tcl list of taco_type options and jlog
 * flags. Events (`account <Added>`) can arrive during this call, so the page
 * must be listening already.
 */
EMSCRIPTEN_KEEPALIVE
int
tacky_start(const char *args)
{
    Tcl_Obj *list, **words, **objv;
    Tcl_Size n, i;
    int code;

    if (interp == NULL) {
        report("FAIL tacky_start before tacky_boot");
        return 1;
    }
    /* A list to split, not a script to eval: a `[` in a page-supplied URL
     * must not become a command substitution. */
    list = Tcl_NewStringObj(args, -1);
    Tcl_IncrRefCount(list);
    if (Tcl_ListObjGetElements(interp, list, &n, &words) != TCL_OK) {
        report("FAIL tacky_start: %s", Tcl_GetStringResult(interp));
        Tcl_DecrRefCount(list);
        return 1;
    }
    objv = (Tcl_Obj **)Tcl_Alloc(sizeof(Tcl_Obj *) * (size_t)(n + 1));
    objv[0] = Tcl_NewStringObj("tackyd_embed_init", -1);
    for (i = 0; i < n; i++) {
        objv[i + 1] = words[i];
    }
    for (i = 0; i <= n; i++) { Tcl_IncrRefCount(objv[i]); }
    code = Tcl_EvalObjv(interp, n + 1, objv, TCL_EVAL_GLOBAL);
    for (i = 0; i <= n; i++) { Tcl_DecrRefCount(objv[i]); }
    Tcl_Free((char *)objv);
    Tcl_DecrRefCount(list);
    if (code != TCL_OK) {
        report("FAIL tackyd_embed_init: %s", Tcl_GetStringResult(interp));
        return 1;
    }
    report("ok started");
    return 0;
}

/*
 * Write the filesystem back to IndexedDB every `seconds`, on Tcl's timer.
 * For the IDBFS fallback only; the worker knows which storage it got, hence
 * a separate call. Periodic rather than per write: IDBFS copies whole files.
 */
EMSCRIPTEN_KEEPALIVE
int
tacky_persist(int seconds)
{
    Tcl_Obj *script;
    int code;

    if (interp == NULL) {
        report("FAIL tacky_persist before tacky_boot");
        return 1;
    }
    script = Tcl_ObjPrintf(
        "proc tacky_persist_loop {} {\n"
        "    catch {tacky_sync}\n"
        "    after %d tacky_persist_loop\n"
        "}\n"
        "after %d tacky_persist_loop", seconds * 1000, seconds * 1000);
    Tcl_IncrRefCount(script);
    code = Tcl_EvalObjEx(interp, script, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(script);
    if (code != TCL_OK) {
        report("FAIL persistence loop: %s", Tcl_GetStringResult(interp));
        return 1;
    }
    return 0;
}

/*
 * The main loop: `vwait forever`. Asyncify unwinds inside it, so call with
 * {async: true}. Returns when ::forever is written: a stop, or a fatal error.
 */
EMSCRIPTEN_KEEPALIVE
int
tacky_run(void)
{
    if (interp == NULL) {
        report("FAIL tacky_run before tacky_boot");
        return 1;
    }
    report("ok running");
    if (Tcl_Eval(interp, "vwait ::forever") != TCL_OK) {
        report("FAIL vwait: %s", Tcl_GetStringResult(interp));
        return 1;
    }
    report("ok stopped");
    return 0;
}
