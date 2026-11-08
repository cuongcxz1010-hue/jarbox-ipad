#ifndef J2ME_UI_H
#define J2ME_UI_H

#include "jvm.h"

#ifdef __cplusplus
extern "C" {
#endif

// UI events posted to the input queue (keep in sync with MIDletRunner.java)
#define J2ME_UI_COMMAND_ACTION   10     // keyCode = command position
#define J2ME_UI_LIST_SELECT      11     // keyCode = row
#define J2ME_UI_ALERT_DISMISSED  12
#define J2ME_UI_ITEM_VALUE       13     // x = item; the value is in j2me_ui_set_text_result
#define J2ME_UI_ITEM_COMMAND     14     // x = item, y = command position

/// Register UI-related native methods with the JVM.
void j2me_ui_reg_natives(MiniJVM *jvm);

/// Called on a JVM thread; `data` is valid only during the call.
typedef void (*j2me_ui_callback)(int action, const char *data);

void j2me_ui_set_callback(j2me_ui_callback callback);

#define J2ME_UI_ACTION_SHOW_CANVAS      1
#define J2ME_UI_ACTION_SHOW_SCREEN      2   // data = JSON document (see ScreenWriter.java)
#define J2ME_UI_ACTION_CANVAS_COMMANDS  3   // data = JSON document
#define J2ME_UI_ACTION_FAILURE          4   // data = message

/// Store a value entered natively; Java reads it when the matching event arrives.
void j2me_ui_set_text_result(int index, const char *utf8);

#ifdef __cplusplus
}
#endif

#endif /* J2ME_UI_H */
