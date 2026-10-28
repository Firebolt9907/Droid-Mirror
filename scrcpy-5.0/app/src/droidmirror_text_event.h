#ifndef DROIDMIRROR_TEXT_EVENT_H
#define DROIDMIRROR_TEXT_EVENT_H
#include <SDL3/SDL_events.h>
// Shared with the Cocoa shim. data1 owns malloc-allocated UTF-8 text.
#define SC_EVENT_SYNTHETIC_TEXT (SDL_EVENT_USER + 0x444d)
#endif
