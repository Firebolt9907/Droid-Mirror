#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/droidmirror_keymap.h"

int main(void) {
    SDL_KeyboardEvent command = { .type = SDL_EVENT_KEY_DOWN, .key = SDLK_LGUI,
        .scancode = SDL_SCANCODE_LGUI, .mod = SDL_KMOD_LGUI };
    SDL_KeyboardEvent result = sc_droidmirror_swap_command_control(command);
    assert(result.key == SDLK_LCTRL && result.scancode == SDL_SCANCODE_LCTRL);
    assert(result.mod == SDL_KMOD_LCTRL);
    command.type = SDL_EVENT_KEY_UP; command.mod = 0;
    result = sc_droidmirror_swap_command_control(command);
    assert(result.type == SDL_EVENT_KEY_UP && result.key == SDLK_LCTRL && result.mod == 0);
    SDL_KeyboardEvent right = { .key = SDLK_RCTRL, .scancode = SDL_SCANCODE_RCTRL, .mod = SDL_KMOD_RCTRL };
    result = sc_droidmirror_swap_command_control(right);
    assert(result.key == SDLK_RGUI && result.scancode == SDL_SCANCODE_RGUI && result.mod == SDL_KMOD_RGUI);
    for (unsigned bits = 0; bits < 16; ++bits) {
        SDL_KeyboardEvent event = { .key = SDLK_C, .scancode = SDL_SCANCODE_C,
            .mod = SDL_KMOD_LSHIFT | SDL_KMOD_RALT | SDL_KMOD_CAPS };
        if (bits & 1) event.mod |= SDL_KMOD_LCTRL;
        if (bits & 2) event.mod |= SDL_KMOD_RCTRL;
        if (bits & 4) event.mod |= SDL_KMOD_LGUI;
        if (bits & 8) event.mod |= SDL_KMOD_RGUI;
        result = sc_droidmirror_swap_command_control(event);
        assert(result.key == SDLK_C && result.scancode == SDL_SCANCODE_C);
        assert(!!(result.mod & SDL_KMOD_LCTRL) == !!(event.mod & SDL_KMOD_LGUI));
        assert(!!(result.mod & SDL_KMOD_RCTRL) == !!(event.mod & SDL_KMOD_RGUI));
        assert(!!(result.mod & SDL_KMOD_LGUI) == !!(event.mod & SDL_KMOD_LCTRL));
        assert(!!(result.mod & SDL_KMOD_RGUI) == !!(event.mod & SDL_KMOD_RCTRL));
        assert((result.mod & ~(SDL_KMOD_CTRL | SDL_KMOD_GUI)) == (event.mod & ~(SDL_KMOD_CTRL | SDL_KMOD_GUI)));
        assert(sc_droidmirror_swap_command_control(result).mod == event.mod);
    }
    SDL_KeyboardEvent paste = { .key = SDLK_V, .scancode = SDL_SCANCODE_V, .mod = SDL_KMOD_LGUI };
    result = sc_droidmirror_swap_command_control(paste);
    assert(result.key == SDLK_V && (result.mod & SDL_KMOD_CTRL) && !(result.mod & SDL_KMOD_GUI));
    puts("PASS: left/right Command-Control swap, modifier releases, copy/paste chords, simultaneous modifiers and unchanged Shift/Option/Caps");
}
