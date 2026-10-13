#include <assert.h>
#include <stdio.h>
#include "../scrcpy-5.0/app/src/control_msg.c"

int main(void) {
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_UHID_INPUT; assert(!sc_control_msg_is_droppable(&msg));
    msg.type = SC_CONTROL_MSG_TYPE_UHID_CREATE; assert(!sc_control_msg_is_droppable(&msg));
    msg.type = SC_CONTROL_MSG_TYPE_UHID_DESTROY; assert(!sc_control_msg_is_droppable(&msg));
    msg.type = SC_CONTROL_MSG_TYPE_INJECT_SCROLL_EVENT; assert(sc_control_msg_is_droppable(&msg));
    puts("PASS: UHID keyboard transitions remain non-droppable under Wi-Fi backpressure");
}
