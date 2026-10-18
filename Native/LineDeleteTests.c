#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/droidmirror_line_delete.h"

static struct sc_key_event captured[4];
static unsigned count;

static void capture(struct sc_key_processor *kp,
                    const struct sc_key_event *event, uint64_t sequence) {
    (void) kp;
    assert(sequence == 17);
    assert(count < ARRAY_LEN(captured));
    captured[count++] = *event;
}

int main(void) {
    const struct sc_key_processor_ops ops = { .process_key = capture };
    struct sc_key_processor kp = { .ops = &ops };
    const uint16_t modifiers[] = {
        SC_MOD_LCTRL, SC_MOD_RCTRL, SC_MOD_LCTRL | SC_MOD_RCTRL,
        SC_MOD_LCTRL | SC_MOD_CAPS | SC_MOD_NUM,
    };
    // Repeated invocations must always contain complete presses/releases.
    for (unsigned repeat = 0; repeat < 2; ++repeat) {
        for (unsigned i = 0; i < ARRAY_LEN(modifiers); ++i) {
            count = 0;
            sc_droidmirror_delete_to_line_start(&kp, modifiers[i], 17);
            assert(count == 4);
            uint16_t locks = modifiers[i] & (SC_MOD_CAPS | SC_MOD_NUM);
            for (unsigned j = 0; j < count; ++j) {
                assert(captured[j].action == (j % 2 ? SC_ACTION_UP : SC_ACTION_DOWN));
                assert(!captured[j].repeat);
                assert(captured[j].keycode == (j < 2 ? SC_KEYCODE_HOME : SC_KEYCODE_BACKSPACE));
                assert(captured[j].scancode == (j < 2 ? SC_SCANCODE_HOME : SC_SCANCODE_BACKSPACE));
                assert(captured[j].mods_state == (j < 2 ? locks | SC_MOD_LSHIFT
                                                     : j == 2 ? locks : modifiers[i]));
            }
        }
    }
    puts("PASS: line deletion selects with Shift+Home, deletes without Control, and restores held modifiers");
}
