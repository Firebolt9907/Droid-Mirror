#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/startup_reveal.h"
int main(void) {
    struct sc_startup_reveal state = {0};
    assert(sc_startup_reveal_update(&state, 0, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1499, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1499, false) == SC_REVEAL_ANIMATE);
    assert(sc_startup_reveal_update(&state, 1500, true) == SC_REVEAL_IMMEDIATE);
    state = (struct sc_startup_reveal){0}; // Retry starts a fresh deadline.
    assert(sc_startup_reveal_update(&state, 5000, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 6499, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 6500, true) == SC_REVEAL_IMMEDIATE);
    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 0, false) == SC_REVEAL_ANIMATE);
    puts("Startup reveal: transient black waits for content; real black gets bounded, animation-free fallback");
}
