/*
 * lib_driver.c - minimal C driver proving dist/libtacky.a links and answers a
 * request end-to-end with no Qt and no zippy exe. Runs the create -> account
 * list -> destroy cycle several times to catch per-create global-state bugs.
 *
 * Build and run via `make test-lib`, or by hand from the tacky_t root:
 *   g++ -pthread -I embed -o build/linux/lib_driver tests/lib_driver.c \
 *       -Wl,--start-group dist/libtacky.a -Wl,--end-group \
 *       -ldl -lz -lm -static-libstdc++
 */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "tacky.h"

struct ctx {
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    int             got;   /* saw the result for token 1 */
};

/* Fires on the backend thread; copy nothing lasting, just check + signal. */
static void on_emit(void *ud, const char *json, size_t len) {
    struct ctx *c = (struct ctx *)ud;
    printf("  emit: %.*s\n", (int)len, json);
    if (strncmp(json, "[\"result\",1,", 12) == 0) {
        pthread_mutex_lock(&c->lock);
        c->got = 1;
        pthread_cond_signal(&c->cond);
        pthread_mutex_unlock(&c->lock);
    }
}

/* One create -> account list -> destroy cycle. Returns 1 on success. */
static int one_cycle(int n) {
    struct ctx c;
    pthread_mutex_init(&c.lock, NULL);
    pthread_cond_init(&c.cond, NULL);
    c.got = 0;

    printf("cycle %d: create\n", n);
    tacky_client *cl = tacky_create(NULL, on_emit, &c);
    if (!cl) {
        fprintf(stderr, "cycle %d: FAIL tacky_create returned NULL\n", n);
        return 0;
    }

    const char *req = "[\"account\",\"list\",{},1]";
    tacky_send(cl, req, strlen(req));

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;

    pthread_mutex_lock(&c.lock);
    int rc = 0;
    while (!c.got && rc == 0)
        rc = pthread_cond_timedwait(&c.cond, &c.lock, &deadline);
    int got = c.got;
    pthread_mutex_unlock(&c.lock);

    tacky_destroy(cl);

    if (!got) {
        fprintf(stderr, "cycle %d: FAIL timed out\n", n);
        return 0;
    }
    printf("cycle %d: ok\n", n);
    return 1;
}

int main(void) {
    for (int i = 1; i <= 3; i++) {
        if (!one_cycle(i))
            return 1;
    }
    printf("PASS: all cycles ok\n");
    return 0;
}
