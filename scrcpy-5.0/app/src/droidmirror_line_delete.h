#ifndef DROIDMIRROR_LINE_DELETE_H
#define DROIDMIRROR_LINE_DELETE_H

#include "trait/key_processor.h"

// Use the active keyboard transport so this works with SDK and HID input,
// including Bluetooth. Temporarily release Control, then explicitly press and
// release Left Shift around Home so the Android text framework
// (MetaKeyKeyListener/ArrowKeyMovementMethod) activates text selection rather
// than moving the cursor or treating Home as top-of-document. Finally, send
// Backspace to delete the selected line and restore held Control.
static inline void
sc_droidmirror_delete_to_line_start(struct sc_key_processor *kp,
                                   uint16_t mods, uint64_t sequence) {
    uint16_t plain = mods & ~(SC_MOD_LCTRL | SC_MOD_RCTRL
                           | SC_MOD_LSHIFT | SC_MOD_RSHIFT);
    enum sc_keycode ctrl_keycode = (mods & SC_MOD_RCTRL) ? SC_KEYCODE_RCTRL : SC_KEYCODE_LCTRL;
    enum sc_scancode ctrl_scancode = (mods & SC_MOD_RCTRL) ? SC_SCANCODE_RCTRL : SC_SCANCODE_LCTRL;
    bool had_ctrl = (mods & (SC_MOD_LCTRL | SC_MOD_RCTRL)) != 0;

    if (had_ctrl) {
        struct sc_key_event release_ctrl = {
            .action = SC_ACTION_UP,
            .keycode = ctrl_keycode,
            .scancode = ctrl_scancode,
            .mods_state = plain,
        };
        kp->ops->process_key(kp, &release_ctrl, sequence);
    }

    struct sc_key_event events[] = {
        { .action = SC_ACTION_DOWN, .keycode = SC_KEYCODE_LSHIFT,
          .scancode = SC_SCANCODE_LSHIFT, .mods_state = plain | SC_MOD_LSHIFT },
        { .action = SC_ACTION_DOWN, .keycode = SC_KEYCODE_HOME,
          .scancode = SC_SCANCODE_HOME, .mods_state = plain | SC_MOD_LSHIFT },
        { .action = SC_ACTION_UP, .keycode = SC_KEYCODE_HOME,
          .scancode = SC_SCANCODE_HOME, .mods_state = plain | SC_MOD_LSHIFT },
        { .action = SC_ACTION_UP, .keycode = SC_KEYCODE_LSHIFT,
          .scancode = SC_SCANCODE_LSHIFT, .mods_state = plain },
        { .action = SC_ACTION_DOWN, .keycode = SC_KEYCODE_BACKSPACE,
          .scancode = SC_SCANCODE_BACKSPACE, .mods_state = plain },
        { .action = SC_ACTION_UP, .keycode = SC_KEYCODE_BACKSPACE,
          .scancode = SC_SCANCODE_BACKSPACE, .mods_state = plain },
    };
    for (unsigned i = 0; i < ARRAY_LEN(events); ++i) {
        kp->ops->process_key(kp, &events[i], sequence);
    }

    if (had_ctrl) {
        struct sc_key_event restore_ctrl = {
            .action = SC_ACTION_DOWN,
            .keycode = ctrl_keycode,
            .scancode = ctrl_scancode,
            .mods_state = mods,
        };
        kp->ops->process_key(kp, &restore_ctrl, sequence);
    }
}

#endif
