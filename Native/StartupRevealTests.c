#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/startup_reveal.h"
int main(void) {
    struct sc_startup_reveal state = {0};
    assert(sc_startup_reveal_update(&state, 0, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 100, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 249, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 250, true) == SC_REVEAL_ANIMATE);

    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 0, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 100, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 200, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 349, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 350, true) == SC_REVEAL_ANIMATE);

    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 5000, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 6499, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 6500, false) == SC_REVEAL_IMMEDIATE);
    // Late/unconfirmed content must not run an animation at the deadline.
    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 0, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1499, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1500, true) == SC_REVEAL_IMMEDIATE);
    // Retry and a static first frame both get a fresh confirmation period.
    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 9000, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 9150, true) == SC_REVEAL_ANIMATE);
    puts("PASS: entrance requires sustained content; black interrupts confirmation; static content confirms; fallback never animates");
}
