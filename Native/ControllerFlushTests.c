#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "controller.h"
#include "android/input.h"
#include "android/keycodes.h"

static void ended(struct sc_controller *controller, bool error, void *userdata) {
    (void)controller; (void)error; (void)userdata;
}
int main(void) {
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    static const struct sc_controller_callbacks cbs = { .on_ended = ended };
    struct sc_controller controller;
    assert(sc_controller_init(&controller, sockets[0], &cbs, NULL));
    struct sc_control_msg msg = { .type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE,
        .inject_keycode = { .keycode = AKEYCODE_SHIFT_LEFT,
            .action = AKEY_EVENT_ACTION_DOWN } };
    assert(sc_controller_push_msg(&controller, &msg));
    msg.inject_keycode.action = AKEY_EVENT_ACTION_UP;
    assert(sc_controller_push_msg(&controller, &msg));
    // A queued release must survive queue backpressure.
    assert(!sc_control_msg_is_droppable(&msg));
    assert(sc_controller_start(&controller));
    assert(sc_controller_flush(&controller, sc_tick_now() + SC_TICK_FROM_SEC(1)));
    uint8_t expected[SC_CONTROL_MSG_MAX_SIZE], received[SC_CONTROL_MSG_MAX_SIZE];
    msg.inject_keycode.action = AKEY_EVENT_ACTION_DOWN;
    size_t length = sc_control_msg_serialize(&msg, expected);
    assert(net_recv_all(sockets[1], received, length) == (ssize_t)length);
    assert(!memcmp(expected, received, length));
    msg.inject_keycode.action = AKEY_EVENT_ACTION_UP;
    length = sc_control_msg_serialize(&msg, expected);
    assert(net_recv_all(sockets[1], received, length) == (ssize_t)length);
    assert(!memcmp(expected, received, length));
    sc_controller_stop(&controller);
    net_interrupt(sockets[0]);
    sc_controller_join(&controller);
    sc_controller_destroy(&controller);
    close(sockets[0]); close(sockets[1]);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(sc_controller_init(&controller, sockets[0], &cbs, NULL));
    assert(sc_controller_push_msg(&controller, &msg));
    sc_tick start = sc_tick_now();
    assert(!sc_controller_flush(&controller, start + SC_TICK_FROM_MS(20)));
    assert(sc_tick_now() - start < SC_TICK_FROM_MS(500));
    sc_controller_destroy(&controller);
    close(sockets[0]); close(sockets[1]);
    puts("PASS: release messages reach transport in order; drain timeout remains bounded");
}
