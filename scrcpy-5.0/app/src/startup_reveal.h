#ifndef SC_STARTUP_REVEAL_H
#define SC_STARTUP_REVEAL_H
#include <stdbool.h>
#include <stdint.h>

struct sc_startup_reveal {
    bool started;
    bool confirming_content;
    uint64_t started_at;
    uint64_t content_since;
};
enum sc_startup_reveal_action { SC_REVEAL_WAIT, SC_REVEAL_ANIMATE, SC_REVEAL_IMMEDIATE };

// Require content to stay on the presented surface for 150 ms. A startup flash
// followed by black must not consume the entrance animation. Uninspectable
// frames are not confirmation; black/protected screens remain usable via the
// bounded fallback, which never animates.
static inline enum sc_startup_reveal_action
sc_startup_reveal_update(struct sc_startup_reveal *state, uint64_t now, bool content) {
    if (!state->started) { state->started = true; state->started_at = now; }
    if (content) {
        if (!state->confirming_content) {
            state->confirming_content = true;
            state->content_since = now;
        }
        if (now - state->content_since >= 150) return SC_REVEAL_ANIMATE;
    } else {
        state->confirming_content = false;
    }
    return now - state->started_at < 1500 ? SC_REVEAL_WAIT : SC_REVEAL_IMMEDIATE;
}
#endif
