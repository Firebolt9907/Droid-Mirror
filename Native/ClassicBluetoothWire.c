#include "ClassicBluetoothWire.h"
#include <string.h>
void dm_classic_wire_init(DMClassicWire *wire) { memset(wire, 0, sizeof(*wire)); }
bool dm_classic_wire_feed(DMClassicWire *wire, const uint8_t *bytes, size_t length,
                          DMWireVideo video, DMWireEvent event, void *context) {
    while (length) {
        if (!wire->decided) {
            size_t take = 8 - wire->magic_used;
            if (take > length) take = length;
            memcpy(wire->magic + wire->magic_used, bytes, take);
            wire->magic_used += take; bytes += take; length -= take;
            if (wire->magic_used < 8) continue;
            wire->decided = true;
            if (memcmp(wire->magic, "DMBT0003", 8)) {
                if (wire->magic[0] != 0) return false;
                wire->legacy = true;
                if (!video(context, wire->magic, 8)) return false;
            }
        }
        if (wire->legacy) return !length || video(context, bytes, length);
        if (!wire->remaining) {
            size_t take = 5 - wire->header_used;
            if (take > length) take = length;
            memcpy(wire->header + wire->header_used, bytes, take);
            wire->header_used += take; bytes += take; length -= take;
            if (wire->header_used < 5) continue;
            wire->type = wire->header[0]; wire->header_used = 0;
            wire->remaining = (uint32_t)wire->header[1] << 24 | (uint32_t)wire->header[2] << 16
                            | (uint32_t)wire->header[3] << 8 | wire->header[4];
            if ((wire->type == 0 && (!wire->remaining || wire->remaining > 16384))
                    || (wire->type == 1 && wire->remaining != 1) || wire->type > 1) return false;
        }
        size_t take = wire->remaining;
        if (take > length) take = length;
        if (!take) continue;
        if (wire->type == 0) { if (!video(context, bytes, take)) return false; }
        else {
            if (bytes[0] < 1 || bytes[0] > 5) return false;
            event(context, bytes[0]);
        }
        wire->remaining -= (uint32_t)take; bytes += take; length -= take;
    }
    return true;
}
bool dm_classic_wire_complete(const DMClassicWire *wire) {
    return wire->decided && (wire->legacy || (!wire->remaining && !wire->header_used));
}
