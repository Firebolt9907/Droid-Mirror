#include <assert.h>
#include <stdio.h>
#define sc_controller_push_msg test_push_msg
#define SDL_GetClipboardText test_clipboard_text
#include "../scrcpy-5.0/app/src/input_manager.c"
#include "../scrcpy-5.0/app/src/hid/hid_keyboard.c"

static struct sc_key_event last_key;
static uint64_t last_ack;
static unsigned clipboard_updates;
static bool synthetic_paste;
static struct sc_hid_keyboard hid;
static struct sc_hid_input report;

char *test_clipboard_text(void) { return SDL_strdup("test fixture, not the user's clipboard"); }
bool test_push_msg(struct sc_controller *controller, const struct sc_control_msg *msg) {
    assert(msg->type == SC_CONTROL_MSG_TYPE_SET_CLIPBOARD);
    if (synthetic_paste) {
        assert(msg->set_clipboard.sequence == SC_SEQUENCE_INVALID && msg->set_clipboard.paste);
        assert(!strcmp(msg->set_clipboard.text, "😀 https://example.com/"));
    } else {
        assert(msg->set_clipboard.sequence == 1 && !msg->set_clipboard.paste);
    }
    ++clipboard_updates;
    free(msg->set_clipboard.text);
    return true;
}
static void capture(struct sc_key_processor *kp, const struct sc_key_event *event, uint64_t sequence) {
    last_key = *event; last_ack = sequence;
    assert(sc_hid_keyboard_generate_input_from_key(&hid, &report, event));
}
int main(void) {
    const struct sc_key_processor_ops ops = { .process_key = capture };
    struct sc_key_processor keyboard = { .ops = &ops, .hid = true, .async_paste = true };
    struct sc_controller controller = {0};
    struct sc_screen screen = {0};
    struct sc_input_manager im = { .controller = &controller, .kp = &keyboard, .screen = &screen,
        .sdl_shortcut_mods = SDL_KMOD_LGUI, .clipboard_autosync = true, .next_sequence = 1 };
    sc_hid_keyboard_init(&hid);
    SDL_KeyboardEvent event = { .type = SDL_EVENT_KEY_DOWN, .key = SDLK_LGUI,
        .scancode = SDL_SCANCODE_LGUI, .mod = SDL_KMOD_LGUI };
    sc_input_manager_process_key(&im, &event);
    assert(last_key.scancode == SC_SCANCODE_LCTRL);
    assert(report.data[0] == SC_HID_MOD_LEFT_CONTROL);
    event.key = SDLK_C; event.scancode = SDL_SCANCODE_C;
    sc_input_manager_process_key(&im, &event);
    assert(last_key.keycode == sc_keycode_from_sdl(SDLK_C) && last_key.mods_state == SC_MOD_LCTRL);
    assert(report.data[0] == SC_HID_MOD_LEFT_CONTROL && clipboard_updates == 0);
    event.type = SDL_EVENT_KEY_UP;
    sc_input_manager_process_key(&im, &event);
    event.type = SDL_EVENT_KEY_DOWN; event.key = SDLK_V; event.scancode = SDL_SCANCODE_V;
    sc_input_manager_process_key(&im, &event);
    assert(clipboard_updates == 1 && last_ack == 1 && im.next_sequence == 2);
    assert(last_key.keycode == sc_keycode_from_sdl(SDLK_V) && last_key.mods_state == SC_MOD_LCTRL);
    assert(report.data[0] == SC_HID_MOD_LEFT_CONTROL);
    event.type = SDL_EVENT_KEY_UP;
    sc_input_manager_process_key(&im, &event);
    event.type = SDL_EVENT_KEY_DOWN; event.key = SDLK_BACKSPACE; event.scancode = SDL_SCANCODE_BACKSPACE; event.mod = SDL_KMOD_LGUI;
    sc_input_manager_process_key(&im, &event);
    // After line deletion with Command held, Control is restored.
    assert(last_key.scancode == SC_SCANCODE_LCTRL && last_key.action == SC_ACTION_DOWN && last_key.mods_state == SC_MOD_LCTRL);
    assert(report.data[0] == SC_HID_MOD_LEFT_CONTROL);
    event.key = SDLK_LGUI; event.scancode = SDL_SCANCODE_LGUI; event.mod = 0;
    sc_input_manager_process_key(&im, &event);
    assert(report.data[0] == 0 && last_key.scancode == SC_SCANCODE_LCTRL);
    event.type = SDL_EVENT_KEY_DOWN; event.key = SDLK_RCTRL; event.scancode = SDL_SCANCODE_RCTRL; event.mod = SDL_KMOD_RCTRL;
    sc_input_manager_process_key(&im, &event);
    assert(report.data[0] == SC_HID_MOD_RIGHT_GUI);
    synthetic_paste = true;
    SDL_Event text = { .type = SC_EVENT_SYNTHETIC_TEXT };
    text.user.data1 = strdup("😀 https://example.com/");
    sc_input_manager_handle_event(&im, &text);
    assert(clipboard_updates == 2);
    // Text injection must not emit a physical A (or any other HID key).
    assert(last_key.scancode == SC_SCANCODE_RGUI);
    im.disconnected = true;
    text.user.data1 = strdup("discard while disconnected");
    sc_input_manager_handle_event(&im, &text);
    assert(clipboard_updates == 2);
    puts("PASS: real input handler and HID reports, Cmd+C, Cmd+V clipboard synchronization/ack, modifier release, Ctrl→GUI, default Super shortcut bypass");
}
