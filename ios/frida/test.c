#include "frida-core.h"
#include <stdio.h>
#include <string.h>

static GMainLoop *loop;
static void on_message(FridaScript *script, const gchar *message, GBytes *data, gpointer user_data){
    printf("MSG: %s\n", message);
    fflush(stdout);
    if (g_main_loop_is_running(loop)) g_main_loop_quit(loop);
}
int main(int argc, char **argv){
    const char *addr = argc > 1 ? argv[1] : "127.0.0.1:27042";
    const char *proc = argc > 2 ? argv[2] : "SpringBoard";
    frida_init();
    loop = g_main_loop_new(NULL, TRUE);
    GError *error = NULL;
    FridaDeviceManager *manager = frida_device_manager_new();
    FridaDevice *device = frida_device_manager_add_remote_device_sync(manager, addr, NULL, NULL, &error);
    if (!device) { printf("add remote failed: %s\n", error ? error->message : "?"); return 1; }
    FridaProcessList *procs = frida_device_enumerate_processes_sync(device, FRIDA_SCOPE_MINIMAL, NULL, &error);
    if (!procs) { printf("enum failed: %s\n", error ? error->message : "?"); return 1; }
    guint pid = 0;
    for (gint i = 0; i < frida_process_list_size(procs); i++) {
        FridaProcess *p = frida_process_list_get(procs, i);
        if (strcmp(frida_process_get_name(p), proc) == 0) pid = frida_process_get_pid(p);
        g_object_unref(p);
    }
    printf("target %s pid=%u\n", proc, pid); fflush(stdout);
    if (!pid) return 1;
    FridaSession *session = frida_device_attach_sync(device, pid, NULL, NULL, &error);
    if (!session) { printf("attach failed: %s\n", error ? error->message : "?"); return 1; }
    FridaScriptOptions *opts = frida_script_options_new();
    frida_script_options_set_name(opts, "test");
    frida_script_options_set_runtime(opts, FRIDA_SCRIPT_RUNTIME_QJS);
    const char *src = "send({pid: Process.id, name: Process.name, objc: (typeof ObjC !== 'undefined')});";
    FridaScript *script = frida_session_create_script_sync(session, src, opts, NULL, &error);
    if (!script) { printf("script failed: %s\n", error ? error->message : "?"); return 1; }
    g_signal_connect(script, "message", G_CALLBACK(on_message), NULL);
    frida_script_load_sync(script, NULL, &error);
    if (error) { printf("load failed: %s\n", error->message); return 1; }
    GMainLoop *l = g_main_loop_new(NULL, TRUE);
    loop = l;
    g_timeout_add(5000, (GSourceFunc)g_main_loop_quit, l);
    g_main_loop_run(l);
    return 0;
}
