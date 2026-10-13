#include <assert.h>
#include <stdio.h>

// Compile the real handler; only the controller's transport is replaced.
#define sc_controller_push_msg test_push_msg
#include "../scrcpy-5.0/app/src/input_manager.c"

static struct sc_control_msg captured[4];
static unsigned count;
bool test_push_msg(struct sc_controller *controller, const struct sc_control_msg *msg) {
    assert(controller && count < 4);
    captured[count++] = *msg;
    return true;
}

int main(void) {
    struct sc_controller controller = {0};
    struct sc_key_processor keyboard = {0};
    struct sc_screen screen = {0};
    struct sc_input_manager im = { .controller = &controller, .kp = &keyboard, .screen = &screen };
    SDL_KeyboardEvent key = { .type = SDL_EVENT_KEY_DOWN, .key = SDLK_ESCAPE };
    sc_input_manager_process_key(&im, &key);
    assert(count == 2);
    assert(captured[0].type == SC_CONTROL_MSG_TYPE_INJECT_KEYCODE);
    assert(captured[0].inject_keycode.keycode == AKEYCODE_BACK);
    assert(captured[0].inject_keycode.action == AKEY_EVENT_ACTION_DOWN);
    assert(captured[1].inject_keycode.action == AKEY_EVENT_ACTION_UP);
    assert(captured[1].inject_keycode.keycode == AKEYCODE_BACK);
    key.repeat = true; sc_input_manager_process_key(&im, &key); assert(count == 2);
    key.type = SDL_EVENT_KEY_UP; key.repeat = false;
    sc_input_manager_process_key(&im, &key); assert(count == 2);
    count = 0; key.type = SDL_EVENT_KEY_DOWN; key.mod = SDL_KMOD_GUI | SDL_KMOD_SHIFT;
    sc_input_manager_process_key(&im, &key); assert(count == 2);
    count = 0; im.disconnected = true;
    sc_input_manager_process_key(&im, &key); assert(count == 0);
    im.disconnected = false; im.camera = true;
    sc_input_manager_process_key(&im, &key); assert(count == 0);
    im.camera = false; im.controller = NULL;
    sc_input_manager_process_key(&im, &key); assert(count == 0);
    puts("PASS: Escape sends one Android Back press, consumes key-up/repeat, handles modifiers, respects no-control/disconnect/camera");
}
