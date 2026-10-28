#include "../scrcpy-5.0/app/src/wheel_protocol.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    for (int sign = -1; sign <= 1; sign += 2) {
        double remainder = 0;
        int distance = 0;
        for (int i = 0; i < 1000; ++i) {
            distance += sc_wheel_take_pixels(&remainder, sign * 0.01);
        }
        assert(distance == sign * 10);
        assert(fabs(remainder) < 0.00001);
        for (int i = 0; i < 1000; ++i) {
            distance += sc_wheel_take_pixels(&remainder, -sign * 0.01);
        }
        assert(distance == 0);
    }
    puts("PASS: fractional momentum survives in both directions and reverses without drift");
}
