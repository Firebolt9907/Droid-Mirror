#include <assert.h>
#include <stdio.h>
#define sc_controller_push_msg test_push_msg
#include "../scrcpy-5.0/app/src/input_manager.c"
#include "../scrcpy-5.0/app/src/keyboard_sdk.c"
#include "../scrcpy-5.0/app/src/hid/hid_keyboard.h"

static struct sc_control_msg messages[64];
static unsigned count;
static bool reject;
bool test_push_msg(struct sc_controller *controller, const struct sc_control_msg *msg) {
    assert(controller);
    if (reject) return false;
    assert(count < 64 && msg->type == SC_CONTROL_MSG_TYPE_INJECT_KEYCODE);
    messages[count++] = *msg;
    return true;
}
static void key(struct sc_input_manager *im, uint32_t type, SDL_Keycode code,
                SDL_Scancode scan, SDL_Keymod mods) {
    SDL_Event event = { .key = { .type = type, .key = code,
        .scancode = scan, .mod = mods } };
    sc_input_manager_handle_event(im, &event);
}
static void focus_lost(struct sc_input_manager *im) {
    SDL_Event event = { .type = SDL_EVENT_WINDOW_FOCUS_LOST };
    sc_input_manager_handle_event(im, &event);
}
static struct sc_hid_keyboard hid;
static struct sc_hid_input report;
static void hid_key(struct sc_key_processor *kp, const struct sc_key_event *event,
                    uint64_t sequence) {
    (void)kp; (void)sequence;
    assert(sc_hid_keyboard_generate_input_from_key(&hid, &report, event));
}
int main(void) {
    struct sc_controller controller = {0};
    struct sc_screen screen = {0};
    struct sc_keyboard_sdk sdk;
    sc_keyboard_sdk_init(&sdk, &controller, SC_KEY_INJECT_MODE_TEXT, true);
    struct sc_input_manager im = { .controller = &controller,
        .screen = &screen, .kp = &sdk.key_processor,
        .sdl_shortcut_mods = SDL_KMOD_RALT };
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_LSHIFT, SDL_SCANCODE_LSHIFT, SDL_KMOD_LSHIFT);
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_RCTRL, SDL_SCANCODE_RCTRL, SDL_KMOD_RCTRL);
    // Text mode normally filters A with no Ctrl: cleanup must bypass that filter.
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_A, SDL_SCANCODE_A, SDL_KMOD_RCTRL);
    assert(count == 3);
    focus_lost(&im);
    assert(count == 6);
    for (unsigned i = 3; i < count; ++i) {
        assert(messages[i].inject_keycode.action == AKEY_EVENT_ACTION_UP);
        assert(messages[i].inject_keycode.metastate == 0);
    }
    focus_lost(&im); assert(count == 6); // Idempotent cleanup.
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_LSHIFT, SDL_SCANCODE_LSHIFT, SDL_KMOD_LSHIFT);
    key(&im, SDL_EVENT_KEY_UP, SDLK_LSHIFT, SDL_SCANCODE_LSHIFT, 0);
    sc_input_manager_release_all(&im); assert(count == 8);
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_RSHIFT, SDL_SCANCODE_RSHIFT, SDL_KMOD_RSHIFT);
    reject = true; focus_lost(&im); assert(count == 9);
    reject = false; sc_input_manager_release_all(&im); assert(count == 10);
    // Releasing MOD before the shortcut's key-up must not leave POWER held.
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_P, SDL_SCANCODE_P, SDL_KMOD_RALT);
    focus_lost(&im);
    assert(count == 12 && messages[11].inject_keycode.keycode == AKEYCODE_POWER);
    assert(messages[11].inject_keycode.action == AKEY_EVENT_ACTION_UP);
    static const struct sc_key_processor_ops ops = { .process_key = hid_key };
    struct sc_key_processor keyboard = { .ops = &ops, .hid = true };
    im.kp = &keyboard;
    sc_hid_keyboard_init(&hid);
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_LSHIFT, SDL_SCANCODE_LSHIFT, SDL_KMOD_LSHIFT);
    key(&im, SDL_EVENT_KEY_DOWN, SDLK_A, SDL_SCANCODE_A, SDL_KMOD_LSHIFT);
    assert(report.data[0] != 0 && hid.keys[SC_SCANCODE_A]);
    focus_lost(&im);
    assert(report.data[0] == 0 && !hid.keys[SC_SCANCODE_A]);
    for (unsigned i = 0; i < report.size; ++i) assert(report.data[i] == 0);
    puts("PASS: SDK/HID focus loss, filtered text keys, normal key-up, retries, shortcut release and repeated cleanup");
}
