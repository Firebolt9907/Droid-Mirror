#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/droidmirror_line_delete.h"

static struct sc_key_event captured[8];
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
            assert(count == 8);
            uint16_t locks = modifiers[i] & (SC_MOD_CAPS | SC_MOD_NUM);
            enum sc_keycode ctrl_kc = (modifiers[i] & SC_MOD_RCTRL) ? SC_KEYCODE_RCTRL : SC_KEYCODE_LCTRL;
            enum sc_scancode ctrl_sc = (modifiers[i] & SC_MOD_RCTRL) ? SC_SCANCODE_RCTRL : SC_SCANCODE_LCTRL;

            // 0: Release held Control
            assert(captured[0].action == SC_ACTION_UP && captured[0].keycode == ctrl_kc
                   && captured[0].scancode == ctrl_sc && captured[0].mods_state == locks);
            // 1: Shift down
            assert(captured[1].action == SC_ACTION_DOWN && captured[1].keycode == SC_KEYCODE_LSHIFT
                   && captured[1].scancode == SC_SCANCODE_LSHIFT && captured[1].mods_state == (locks | SC_MOD_LSHIFT));
            // 2: Home down (select to line start)
            assert(captured[2].action == SC_ACTION_DOWN && captured[2].keycode == SC_KEYCODE_HOME
                   && captured[2].scancode == SC_SCANCODE_HOME && captured[2].mods_state == (locks | SC_MOD_LSHIFT));
            // 3: Home up
            assert(captured[3].action == SC_ACTION_UP && captured[3].keycode == SC_KEYCODE_HOME
                   && captured[3].scancode == SC_SCANCODE_HOME && captured[3].mods_state == (locks | SC_MOD_LSHIFT));
            // 4: Shift up
            assert(captured[4].action == SC_ACTION_UP && captured[4].keycode == SC_KEYCODE_LSHIFT
                   && captured[4].scancode == SC_SCANCODE_LSHIFT && captured[4].mods_state == locks);
            // 5: Backspace down (delete selection)
            assert(captured[5].action == SC_ACTION_DOWN && captured[5].keycode == SC_KEYCODE_BACKSPACE
                   && captured[5].scancode == SC_SCANCODE_BACKSPACE && captured[5].mods_state == locks);
            // 6: Backspace up
            assert(captured[6].action == SC_ACTION_UP && captured[6].keycode == SC_KEYCODE_BACKSPACE
                   && captured[6].scancode == SC_SCANCODE_BACKSPACE && captured[6].mods_state == locks);
            // 7: Restore held Control
            assert(captured[7].action == SC_ACTION_DOWN && captured[7].keycode == ctrl_kc
                   && captured[7].scancode == ctrl_sc && captured[7].mods_state == modifiers[i]);

            for (unsigned j = 0; j < count; ++j) {
                assert(!captured[j].repeat);
            }
        }
    }

    // When called with 0 modifiers (no Control held), verify 6 events (no Control release/restore).
    count = 0;
    sc_droidmirror_delete_to_line_start(&kp, 0, 17);
    assert(count == 6);
    assert(captured[0].action == SC_ACTION_DOWN && captured[0].keycode == SC_KEYCODE_LSHIFT);
    assert(captured[1].action == SC_ACTION_DOWN && captured[1].keycode == SC_KEYCODE_HOME);
    assert(captured[2].action == SC_ACTION_UP && captured[2].keycode == SC_KEYCODE_HOME);
    assert(captured[3].action == SC_ACTION_UP && captured[3].keycode == SC_KEYCODE_LSHIFT);
    assert(captured[4].action == SC_ACTION_DOWN && captured[4].keycode == SC_KEYCODE_BACKSPACE);
    assert(captured[5].action == SC_ACTION_UP && captured[5].keycode == SC_KEYCODE_BACKSPACE);

    puts("PASS: line deletion releases Control, selects with Shift+Home, deletes without Control, and restores held Control");
}
