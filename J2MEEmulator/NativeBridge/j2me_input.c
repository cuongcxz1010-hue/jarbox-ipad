//
// j2me_input.c — Input event bridge between the platform and the JVM
//
// A ring buffer filled by the platform and drained by the JVM's main thread.
// The JVM thread sleeps on a condition variable while the queue is empty, so
// an idle game uses no CPU and a key press is delivered immediately.
//

#include "j2me_input.h"
#include "jvm_bridge.h"
#include "jvm.h"
#include "jvm_util.h"
#include "tinycthread.h"
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>

#define INPUT_QUEUE_SIZE 512
#define INPUT_QUEUE_MASK (INPUT_QUEUE_SIZE - 1)

typedef struct {
    int type;
    int x, y;
    int keyCode;
} InputEvent;

static InputEvent g_queue[INPUT_QUEUE_SIZE];
static int g_write_pos = 0;
static int g_read_pos = 0;

static mtx_t g_lock;
static cnd_t g_ready;
static atomic_int g_lock_ready = 0;

static void ensure_lock(void) {
    int state = atomic_load(&g_lock_ready);
    if (state == 2) return;
    int expected = 0;
    if (atomic_compare_exchange_strong(&g_lock_ready, &expected, 1)) {
        mtx_init(&g_lock, mtx_plain);
        cnd_init(&g_ready);
        atomic_store(&g_lock_ready, 2);
    } else {
        while (atomic_load(&g_lock_ready) != 2) { }
    }
}

static int g_canvas_width = 240;
static int g_canvas_height = 320;

void j2me_input_set_canvas_size(int width, int height) {
    g_canvas_width = width;
    g_canvas_height = height;
}

static void enqueue_event(int type, int x, int y, int keyCode) {
    ensure_lock();
    mtx_lock(&g_lock);
    int next = (g_write_pos + 1) & INPUT_QUEUE_MASK;
    if (next != g_read_pos) {
        InputEvent *e = &g_queue[g_write_pos];
        e->type = type;
        e->x = x;
        e->y = y;
        e->keyCode = keyCode;
        g_write_pos = next;
        cnd_signal(&g_ready);
    }
    mtx_unlock(&g_lock);
}

void j2me_input_post_touch(int type, int x, int y) { enqueue_event(type, x, y, 0); }
void j2me_input_post_key(int type, int keyCode) { enqueue_event(type, 0, 0, keyCode); }
void j2me_input_post_event(int type, int x, int y) { enqueue_event(type, x, y, 0); }

void j2me_input_wake(void) {
    ensure_lock();
    mtx_lock(&g_lock);
    cnd_broadcast(&g_ready);
    mtx_unlock(&g_lock);
}

static int dequeue_locked(InputEvent *out) {
    if (g_read_pos == g_write_pos) return 0;
    *out = g_queue[g_read_pos];
    g_read_pos = (g_read_pos + 1) & INPUT_QUEUE_MASK;
    return 1;
}

// NativeBridge.waitInputEvent(timeoutMs) → {type, x, y, keyCode} or null
static s32 n_waitInputEvent(Runtime *runtime, JClass *clazz) {
    s32 timeoutMs = localvar_getInt(runtime->localvar, 0);
    InputEvent evt;
    int got;

    ensure_lock();
    mtx_lock(&g_lock);
    got = dequeue_locked(&evt);
    mtx_unlock(&g_lock);

    if (!got && !jvm_bridge_is_stop_requested()) {
        // The thread is marked as blocked so the garbage collector does not wait for it
        jthread_block_enter(runtime);
        struct timespec until;
        timespec_get(&until, TIME_UTC);
        until.tv_sec += timeoutMs / 1000;
        until.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
        if (until.tv_nsec >= 1000000000L) { until.tv_nsec -= 1000000000L; until.tv_sec += 1; }

        mtx_lock(&g_lock);
        while (!(got = dequeue_locked(&evt)) && !jvm_bridge_is_stop_requested()) {
            int r = cnd_timedwait(&g_ready, &g_lock, &until);
            if (r != thrd_success) {
                got = dequeue_locked(&evt);
                break;
            }
        }
        mtx_unlock(&g_lock);
        jthread_block_exit(runtime);
    }

    if (!got) {
        push_ref(runtime->stack, NULL);
        return RUNTIME_STATUS_NORMAL;
    }

    Instance *arr = jarray_create_by_type_index(runtime, 4, DATATYPE_INT);
    if (arr) {
        s32 *body = (s32 *)arr->arr_body;
        body[0] = evt.type;
        body[1] = evt.x;
        body[2] = evt.y;
        body[3] = evt.keyCode;
    }
    push_ref(runtime->stack, arr);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_wakeInput(Runtime *runtime, JClass *clazz) {
    j2me_input_wake();
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_isStopRequested(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, jvm_bridge_is_stop_requested() ? 1 : 0);
    return RUNTIME_STATUS_NORMAL;
}

void j2me_input_reset(void) {
    ensure_lock();
    mtx_lock(&g_lock);
    g_write_pos = 0;
    g_read_pos = 0;
    mtx_unlock(&g_lock);
}

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_input_methods[] = {
    {CLS, "waitInputEvent",  "(I)[I", n_waitInputEvent},
    {CLS, "wakeInput",       "()V",   n_wakeInput},
    {CLS, "isStopRequested", "()Z",   n_isStopRequested},
};

#undef CLS

void j2me_input_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_input_methods, sizeof(j2me_input_methods) / sizeof(java_native_method));
}
