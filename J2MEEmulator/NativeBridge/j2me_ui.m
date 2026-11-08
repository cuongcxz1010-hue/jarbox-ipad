//
// j2me_ui.m — Bridge for the MIDP high-level screens (Form, List, Alert, TextBox)
//
// Java describes a screen as one JSON document; Swift turns it into views.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "j2me_ui.h"
#include "j2me_input.h"
#include "jvm.h"
#include "jvm_util.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define MAX_TEXT_RESULTS 512

static j2me_ui_callback g_ui_callback = NULL;

static pthread_mutex_t g_text_lock = PTHREAD_MUTEX_INITIALIZER;
static char *g_text_results[MAX_TEXT_RESULTS];

void j2me_ui_set_callback(j2me_ui_callback callback) {
    g_ui_callback = callback;
}

void j2me_ui_set_text_result(int index, const char *utf8) {
    if (index < 0 || index >= MAX_TEXT_RESULTS) return;
    pthread_mutex_lock(&g_text_lock);
    free(g_text_results[index]);
    g_text_results[index] = utf8 ? strdup(utf8) : NULL;
    pthread_mutex_unlock(&g_text_lock);
}

static void call_ui(int action, Instance *jstr, Runtime *runtime) {
    if (!g_ui_callback) return;
    Utf8String *u = utf8_create();
    if (jstr) jstring_2_utf8(jstr, u, runtime);
    g_ui_callback(action, utf8_cstr(u));
    utf8_destroy(u);
}

static s32 n_showScreen(Runtime *runtime, JClass *clazz) {
    call_ui(J2ME_UI_ACTION_SHOW_SCREEN, localvar_getRefer(runtime->localvar, 0), runtime);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setCanvasCommands(Runtime *runtime, JClass *clazz) {
    call_ui(J2ME_UI_ACTION_CANVAS_COMMANDS, localvar_getRefer(runtime->localvar, 0), runtime);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_showCanvas(Runtime *runtime, JClass *clazz) {
    if (g_ui_callback) g_ui_callback(J2ME_UI_ACTION_SHOW_CANVAS, NULL);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_reportFailure(Runtime *runtime, JClass *clazz) {
    call_ui(J2ME_UI_ACTION_FAILURE, localvar_getRefer(runtime->localvar, 0), runtime);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_takeTextResult(Runtime *runtime, JClass *clazz) {
    s32 index = localvar_getInt(runtime->localvar, 0);
    char *value = NULL;
    if (index >= 0 && index < MAX_TEXT_RESULTS) {
        pthread_mutex_lock(&g_text_lock);
        value = g_text_results[index];
        g_text_results[index] = NULL;
        pthread_mutex_unlock(&g_text_lock);
    }
    Instance *jstr = value ? jstring_create_cstr(value, runtime) : NULL;
    free(value);
    push_ref(runtime->stack, jstr);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_platformRequest(Runtime *runtime, JClass *clazz) {
    Instance *jurl = localvar_getRefer(runtime->localvar, 0);
    if (!jurl) return RUNTIME_STATUS_NORMAL;
    Utf8String *u = utf8_create();
    jstring_2_utf8(jurl, u, runtime);
    NSString *text = [NSString stringWithUTF8String:utf8_cstr(u)];
    utf8_destroy(u);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = text ? [NSURL URLWithString:text] : nil;
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    });
    return RUNTIME_STATUS_NORMAL;
}

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_ui_methods[] = {
    {CLS, "showScreen",        "(Ljava/lang/String;)V", n_showScreen},
    {CLS, "setCanvasCommands", "(Ljava/lang/String;)V", n_setCanvasCommands},
    {CLS, "showCanvas",        "()V",                   n_showCanvas},
    {CLS, "reportFailure",     "(Ljava/lang/String;)V", n_reportFailure},
    {CLS, "takeTextResult",    "(I)Ljava/lang/String;", n_takeTextResult},
    {CLS, "platformRequest",   "(Ljava/lang/String;)V", n_platformRequest},
};

#undef CLS

void j2me_ui_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_ui_methods, sizeof(j2me_ui_methods) / sizeof(java_native_method));
}
