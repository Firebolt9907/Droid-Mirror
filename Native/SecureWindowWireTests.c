#include "device_msg.h"
#include "control_msg.h"
#include "secure_screen_gate.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const uint8_t records[] = {4, 1, 1, 2, 3, 4, 4, 0, 1, 2, 3, 4, 4, 2, 1, 2, 3, 4};
    struct sc_device_msg msg;
    for (size_t offset = 0; offset < sizeof(records); offset += 6) {
        for (size_t partial = 0; partial < 6; ++partial)
            assert(sc_device_msg_deserialize(records + offset, partial, &msg) == 0);
        assert(sc_device_msg_deserialize(records + offset, sizeof(records) - offset, &msg) == 6);
        assert(msg.type == DEVICE_MSG_TYPE_SECURE_WINDOW_STATE);
        assert(msg.secure_window_state.state == records[offset + 1]);
        assert(msg.secure_window_state.generation == 0x01020304);
        sc_device_msg_destroy(&msg);
    }
    const uint8_t invalid[] = {4, 3, 0, 0, 0, 1};
    assert(sc_device_msg_deserialize(invalid, sizeof(invalid), &msg) == -1);
    struct sc_control_msg request = {.type = SC_CONTROL_MSG_TYPE_SECURE_WINDOW_CANDIDATE,
        .secure_window_candidate = {.black = true, .generation = 0x01020304}};
    uint8_t bytes[6];
    assert(sc_control_msg_serialize(&request, bytes) == 6);
    const uint8_t expected[] = {26, 1, 1, 2, 3, 4};
    assert(!memcmp(bytes, expected, 6));
    request.secure_window_candidate.black = false;
    assert(sc_control_msg_serialize(&request, bytes) == 6 && bytes[1] == 0);

    struct sc_secure_screen_gate gate = {0};
    assert(!sc_secure_screen_gate_accept(&gate, 0));
    sc_secure_screen_gate_set(&gate, true);
    uint32_t first = gate.generation;
    assert(sc_secure_screen_gate_accept(&gate, first));
    sc_secure_screen_gate_set(&gate, true);
    assert(gate.generation == first); // Repeated black frames preserve the query identity.
    sc_secure_screen_gate_set(&gate, false);
    assert(!sc_secure_screen_gate_accept(&gate, first)); // A slow reply after video recovery is ignored.
    sc_secure_screen_gate_set(&gate, true);
    assert(!sc_secure_screen_gate_accept(&gate, first)); // Nor can it match a new black transition.
    assert(sc_secure_screen_gate_accept(&gate, gate.generation));
    puts("PASS: candidate request/reply wire, fragmentation, normal-video recovery and stale response rejection");
}
