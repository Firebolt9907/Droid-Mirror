#ifndef DROIDMIRROR_LINE_DELETE_H
#define DROIDMIRROR_LINE_DELETE_H

#include "trait/key_processor.h"

// Use the active keyboard transport so this works with SDK and HID input,
// including Bluetooth. Never send Control+Home (start of document).
static inline void
sc_droidmirror_delete_to_line_start(struct sc_key_processor *kp,
                                   uint16_t mods, uint64_t sequence) {
    uint16_t plain = mods & ~(SC_MOD_LCTRL | SC_MOD_RCTRL
                           | SC_MOD_LSHIFT | SC_MOD_RSHIFT);
    struct sc_key_event events[] = {
        { .action = SC_ACTION_DOWN, .keycode = SC_KEYCODE_HOME,
          .scancode = SC_SCANCODE_HOME, .mods_state = plain | SC_MOD_LSHIFT },
        { .action = SC_ACTION_UP, .keycode = SC_KEYCODE_HOME,
          .scancode = SC_SCANCODE_HOME, .mods_state = plain | SC_MOD_LSHIFT },
        { .action = SC_ACTION_DOWN, .keycode = SC_KEYCODE_BACKSPACE,
          .scancode = SC_SCANCODE_BACKSPACE, .mods_state = plain },
        // Restore held modifiers after deleting, including for HID reports.
        { .action = SC_ACTION_UP, .keycode = SC_KEYCODE_BACKSPACE,
          .scancode = SC_SCANCODE_BACKSPACE, .mods_state = mods },
    };
    for (unsigned i = 0; i < ARRAY_LEN(events); ++i) {
        kp->ops->process_key(kp, &events[i], sequence);
    }
}

#endif
