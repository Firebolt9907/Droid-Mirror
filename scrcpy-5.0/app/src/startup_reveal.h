#ifndef SC_STARTUP_REVEAL_H
#define SC_STARTUP_REVEAL_H
#include <stdbool.h>
#include <stdint.h>

struct sc_startup_reveal {
    bool saw_black;
    uint64_t black_since;
};
enum sc_startup_reveal_action { SC_REVEAL_WAIT, SC_REVEAL_ANIMATE, SC_REVEAL_IMMEDIATE };

// Wait out transient blank frames. A genuinely black/protected app must still
// become usable, without running an entrance animation over empty pixels.
static inline enum sc_startup_reveal_action
sc_startup_reveal_update(struct sc_startup_reveal *state, uint64_t now, bool black) {
    if (!black) return SC_REVEAL_ANIMATE;
    if (!state->saw_black) { state->saw_black = true; state->black_since = now; }
    return now - state->black_since < 1500 ? SC_REVEAL_WAIT : SC_REVEAL_IMMEDIATE;
}
#endif
