#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/startup_reveal.h"
int main(void) {
    struct sc_startup_reveal state = {0};
    assert(sc_startup_reveal_update(&state, 0, false, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 100, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 249, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 250, true, false) == SC_REVEAL_ANIMATE);

    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 0, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 100, false, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 200, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 349, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 350, true, false) == SC_REVEAL_ANIMATE);

    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 5000, false, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 6499, false, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 6500, false, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 15000, false, false) == SC_REVEAL_WAIT);
    // A slow startup must retain its entrance after the old 1.5 second deadline.
    assert(sc_startup_reveal_update(&state, 16000, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 16150, true, false) == SC_REVEAL_ANIMATE);
    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 0, false, true) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1500, false, true) == SC_REVEAL_IMMEDIATE);
    // Crossing the old deadline must not expose late/unconfirmed content.
    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 0, false, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1499, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1500, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 1649, true, false) == SC_REVEAL_ANIMATE);
    // Retry and a static first frame both get a fresh confirmation period.
    state = (struct sc_startup_reveal){0};
    assert(sc_startup_reveal_update(&state, 9000, true, false) == SC_REVEAL_WAIT);
    assert(sc_startup_reveal_update(&state, 9150, true, false) == SC_REVEAL_ANIMATE);
    puts("PASS: entrance requires sustained content; black interrupts confirmation; static content confirms; slow black startup retains entrance; unknown fallback never animates");
}
