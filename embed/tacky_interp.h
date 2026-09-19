/*
 * tacky_interp.h - bringing an interpreter up over the bundled backend.
 *
 * Shared by the two libtacky shims: tacky.c, which runs the interpreter on a
 * private thread for a native host, and tacky_wasm.c, which runs it on the
 * one thread a Web Worker has. Everything that is the same for both is here:
 * registering the static packages, mounting the script zip, Tcl_Init, the
 * `tacky_native_emit` command and sourcing bin/tackyd-embed.tcl. What differs
 * - threads, how requests arrive, how emits leave - stays in each shim.
 *
 * Static functions in a header rather than a third source file, the way
 * zippy's static_pkgs.h does it: zippy's `lib` target compiles exactly one
 * shim source, and this keeps it that way.
 */
#ifndef TACKY_INTERP_H
#define TACKY_INTERP_H

#include <stddef.h>
#include <tcl.h>

#include "static_pkgs.h"

/* The mount is process-global (shared across interps), not per-interp, so it
 * happens exactly once: a second interpreter in the same process (a restart,
 * or more than one instance) would otherwise fail with "already mounted". The
 * guard is under a mutex; the mount outlives any single interp. A static
 * Tcl_Mutex is self-initialising on first Tcl_MutexLock. */
static Tcl_Mutex tacky_mount_lock;
static int       tacky_mounted = 0;

/*
 * Bring `interp` up as far as the embed script: everything except `taco`
 * itself, which `tackyd_embed_init` creates once the host has said how.
 *
 *   zip, ziplen   the bundled script tree, mounted read-only and uncopied
 *   emitProc/cd   what `tacky_native_emit {json}` calls; created before the
 *                 embed script because `taco_type`'s constructor emits for
 *                 every account it already knows about
 *
 * Returns TCL_OK, or TCL_ERROR with *stage naming the step that failed and
 * the interpreter's result saying why.
 */
static int
TackyInterpInit(Tcl_Interp *interp, const void *zip, size_t ziplen,
                Tcl_ObjCmdProc *emitProc, void *emitData, const char **stage)
{
    /* NULL, not `interp`: a non-NULL interp makes Tcl_StaticLibrary run every
     * init proc immediately (before Tcl_Init/mount). NULL registers them
     * process-globally and lazily, so `load {} <Name>` resolves on demand -
     * matching how the kitsh launcher registers them. */
    Zippy_RegisterStaticPackages(NULL);

    /* Before Tcl_Init, so init.tcl loads from the zip. */
    Tcl_MutexLock(&tacky_mount_lock);
    if (!tacky_mounted) {
        if (TclZipfs_MountBuffer(interp, zip, ziplen, "//zipfs:/app", 0) != TCL_OK) {
            Tcl_MutexUnlock(&tacky_mount_lock);
            *stage = "TclZipfs_MountBuffer";
            return TCL_ERROR;
        }
        tacky_mounted = 1;
    }
    Tcl_MutexUnlock(&tacky_mount_lock);

    Tcl_SetVar2Ex(interp, "tcl_library", NULL,
        Tcl_NewStringObj("//zipfs:/app/tcl_library", -1), TCL_GLOBAL_ONLY);
    if (Tcl_Init(interp) != TCL_OK) {
        *stage = "Tcl_Init";
        return TCL_ERROR;
    }

    Tcl_CreateObjCommand(interp, "tacky_native_emit", emitProc, emitData, NULL);

    if (Tcl_EvalFile(interp, "//zipfs:/app/bin/tackyd-embed.tcl") != TCL_OK) {
        *stage = "source tackyd-embed.tcl";
        return TCL_ERROR;
    }
    return TCL_OK;
}

#endif /* TACKY_INTERP_H */
