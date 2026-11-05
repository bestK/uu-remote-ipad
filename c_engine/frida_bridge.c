// Minimal frida-core bridge for the iPad host: connect to the local
// frida-server, attach to a process, load a script, forward messages.
#include "frida-core.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

void uu_frida_stop(void *handle);

typedef void (*uu_msg_cb)(const char *message, const void *data, size_t len, void *user);

typedef struct {
    char *address;
    char *process;
    char *source;
    uu_msg_cb cb;
    void *user;
    GMainLoop *loop;
    FridaDeviceManager *manager;
    FridaDevice *device;
    FridaSession *session;
    FridaScript *script;
    volatile int ready;
    volatile int failed;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} UuFrida;

static void on_message(FridaScript *script, const gchar *message, GBytes *data, gpointer user_data) {
    UuFrida *self = user_data;
    const void *bytes = NULL;
    size_t len = 0;
    if (data) bytes = g_bytes_get_data(data, &len);
    if (getenv("UU_FRIDA_DEBUG")) fprintf(stderr, "[frida] msg=%.90s data=%p datalen=%zu\n", message, bytes, len);
    if (self->cb) self->cb(message, bytes, len, self->user);
}

// Only stage and numeric error code: Frida error messages may contain paths or other private data.
static void log_failure(const char *stage, GError *error) {
    fprintf(stderr, "[frida] initialization failed: stage=%s error_present=%d error_code=%d\n",
            stage, error != NULL, error ? error->code : 0);
    if (error) g_error_free(error);
}

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static void do_frida_init(void) { frida_init(); }

static gpointer loop_thread(gpointer arg) {
    UuFrida *self = arg;
    pthread_once(&init_once, do_frida_init);
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);
    GError *error = NULL;
    self->manager = frida_device_manager_new();
    self->device = frida_device_manager_add_remote_device_sync(self->manager, self->address, NULL, NULL, &error);
    if (!self->device) { log_failure("connect", error); self->failed = 1; goto done; }
    FridaProcessList *procs = frida_device_enumerate_processes_sync(self->device, FRIDA_SCOPE_MINIMAL, NULL, &error);
    if (!procs) { log_failure("enumerate", error); self->failed = 1; goto done; }
    guint pid = 0;
    for (gint i = 0; i < frida_process_list_size(procs); i++) {
        FridaProcess *p = frida_process_list_get(procs, i);
        if (strcmp(frida_process_get_name(p), self->process) == 0) pid = frida_process_get_pid(p);
        g_object_unref(p);
    }
    g_object_unref(procs);
    if (!pid) { log_failure("process-not-found", NULL); self->failed = 1; goto done; }
    self->session = frida_device_attach_sync(self->device, pid, NULL, NULL, &error);
    if (!self->session) { log_failure("attach", error); self->failed = 1; goto done; }
    FridaScriptOptions *opts = frida_script_options_new();
    frida_script_options_set_name(opts, "uu-ipad");
    frida_script_options_set_runtime(opts, FRIDA_SCRIPT_RUNTIME_QJS);
    self->script = frida_session_create_script_sync(self->session, self->source, opts, NULL, &error);
    g_object_unref(opts);
    if (!self->script) { log_failure("create-script", error); self->failed = 1; goto done; }
    g_signal_connect(self->script, "message", G_CALLBACK(on_message), self);
    frida_script_load_sync(self->script, NULL, &error);
    if (error) { log_failure("load-script", error); self->failed = 1; goto done; }
    self->loop = g_main_loop_new(ctx, FALSE);
    pthread_mutex_lock(&self->mutex);
    self->ready = 1;
    pthread_cond_broadcast(&self->cond);
    pthread_mutex_unlock(&self->mutex);
    g_main_loop_run(self->loop);
done:
    pthread_mutex_lock(&self->mutex);
    self->ready = 1;
    pthread_cond_broadcast(&self->cond);
    pthread_mutex_unlock(&self->mutex);
    g_main_context_pop_thread_default(ctx);
    return NULL;
}

void *uu_frida_start(const char *address, const char *process, const char *source, uu_msg_cb cb, void *user, int timeout_ms) {
    UuFrida *self = calloc(1, sizeof(UuFrida));
    self->address = strdup(address);
    self->process = strdup(process);
    self->source = strdup(source);
    self->cb = cb;
    self->user = user;
    pthread_mutex_init(&self->mutex, NULL);
    pthread_cond_init(&self->cond, NULL);
    pthread_t thread;
    pthread_create(&thread, NULL, loop_thread, self);
    pthread_detach(thread);
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&self->mutex);
    while (!self->ready) pthread_cond_timedwait(&self->cond, &self->mutex, &deadline);
    int failed = self->failed || !self->ready;
    pthread_mutex_unlock(&self->mutex);
    if (failed) { uu_frida_stop(self); return NULL; }
    return self;
}

void uu_frida_stop(void *handle) {
    UuFrida *self = handle;
    if (!self) return;
    if (self->loop) { g_main_loop_quit(self->loop); }
    if (self->script) { frida_script_unload_sync(self->script, NULL, NULL); g_object_unref(self->script); self->script = NULL; }
    if (self->session) { frida_session_detach_sync(self->session, NULL, NULL); g_object_unref(self->session); self->session = NULL; }
    if (self->device) { g_object_unref(self->device); self->device = NULL; }
    if (self->manager) { frida_device_manager_close_sync(self->manager, NULL, NULL); g_object_unref(self->manager); self->manager = NULL; }
    free(self->address); free(self->process); free(self->source);
    pthread_mutex_destroy(&self->mutex); pthread_cond_destroy(&self->cond);
    free(self);
}

void uu_frida_post(void *handle, const char *json) {
    UuFrida *self = handle;
    if (self && self->script) frida_script_post(self->script, json, NULL);
}
