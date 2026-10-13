#ifndef DROIDMIRROR_KEYMAP_H
#define DROIDMIRROR_KEYMAP_H

#include <SDL3/SDL_events.h>

// Swap both sides independently, including modifier-only key-up events.
// Changing only the flags would leave Android HID modifier reports inconsistent.
static inline SDL_KeyboardEvent
sc_droidmirror_swap_command_control(SDL_KeyboardEvent event) {
    SDL_Keymod original = event.mod;
    event.mod &= ~(SDL_KMOD_CTRL | SDL_KMOD_GUI);
    if (original & SDL_KMOD_LGUI) event.mod |= SDL_KMOD_LCTRL;
    if (original & SDL_KMOD_RGUI) event.mod |= SDL_KMOD_RCTRL;
    if (original & SDL_KMOD_LCTRL) event.mod |= SDL_KMOD_LGUI;
    if (original & SDL_KMOD_RCTRL) event.mod |= SDL_KMOD_RGUI;
    switch (event.key) {
        case SDLK_LGUI: event.key = SDLK_LCTRL; break;
        case SDLK_RGUI: event.key = SDLK_RCTRL; break;
        case SDLK_LCTRL: event.key = SDLK_LGUI; break;
        case SDLK_RCTRL: event.key = SDLK_RGUI; break;
        default: break;
    }
    switch (event.scancode) {
        case SDL_SCANCODE_LGUI: event.scancode = SDL_SCANCODE_LCTRL; break;
        case SDL_SCANCODE_RGUI: event.scancode = SDL_SCANCODE_RCTRL; break;
        case SDL_SCANCODE_LCTRL: event.scancode = SDL_SCANCODE_LGUI; break;
        case SDL_SCANCODE_RCTRL: event.scancode = SDL_SCANCODE_RGUI; break;
        default: break;
    }
    return event;
}

#endif
