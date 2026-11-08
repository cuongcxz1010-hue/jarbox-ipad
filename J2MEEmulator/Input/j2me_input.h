#ifndef J2ME_INPUT_H
#define J2ME_INPUT_H

#include "jvm.h"

#ifdef __cplusplus
extern "C" {
#endif

// Input event types (keep in sync with MIDletRunner.java)
#define J2ME_INPUT_POINTER_PRESSED  0
#define J2ME_INPUT_POINTER_DRAGGED  1
#define J2ME_INPUT_POINTER_RELEASED 2
#define J2ME_INPUT_KEY_PRESSED      3
#define J2ME_INPUT_KEY_RELEASED     4
#define J2ME_INPUT_KEY_REPEATED     5

// Application events
#define J2ME_APP_FPS_OVERRIDE       20      // keyCode = fps; -1 = game setting, 0 = unlimited
#define J2ME_APP_BACKGROUND         21
#define J2ME_APP_FOREGROUND         22

/// Register input-related native methods with the JVM.
void j2me_input_reg_natives(MiniJVM *jvm);

/// Post a touch event (virtual canvas coordinates).
void j2me_input_post_touch(int type, int x, int y);

/// Post a key or other event; `keyCode` carries the argument.
void j2me_input_post_key(int type, int keyCode);

/// Post an event with two integer arguments (x, y).
void j2me_input_post_event(int type, int x, int y);

/// Wake the thread waiting in waitInputEvent (stop requests).
void j2me_input_wake(void);

void j2me_input_set_canvas_size(int width, int height);

/// Reset input state (clear ring buffer). Call between game sessions.
void j2me_input_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* J2ME_INPUT_H */
