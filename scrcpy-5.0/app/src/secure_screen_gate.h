#ifndef SC_SECURE_SCREEN_GATE_H
#define SC_SECURE_SCREEN_GATE_H

#include <stdbool.h>
#include <stdint.h>

// Main-thread state: correlate shell replies with the current black-screen episode.
struct sc_secure_screen_gate {
    bool black;
    uint32_t generation;
};

static inline void
sc_secure_screen_gate_set(struct sc_secure_screen_gate *gate, bool black) {
    if (black != gate->black) {
        gate->black = black;
        ++gate->generation;
    }
}

static inline bool
sc_secure_screen_gate_accept(const struct sc_secure_screen_gate *gate, uint32_t generation) {
    return gate->black && gate->generation == generation;
}

#endif
