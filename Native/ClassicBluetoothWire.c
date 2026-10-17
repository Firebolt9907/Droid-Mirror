#include "ClassicBluetoothWire.h"
#include <string.h>
void dm_classic_wire_init(DMClassicWire *wire) { memset(wire, 0, sizeof(*wire)); }
void dm_classic_wire_init_video_only(DMClassicWire *wire) {
    dm_classic_wire_init(wire); wire->require_video_only = true;
}
bool dm_classic_wire_feed_ble(DMClassicWire *wire, const uint8_t *bytes, size_t length,
                          DMWireVideo video, DMWireEvent event, DMWireVideo control, DMWireVideo setup, void *context) {
    while (length) {
        if (!wire->decided) {
            size_t take = 8 - wire->magic_used;
            if (take > length) take = length;
            memcpy(wire->magic + wire->magic_used, bytes, take);
            wire->magic_used += take; bytes += take; length -= take;
            if (wire->magic_used < 8) continue;
            wire->decided = true;
            wire->video_only = !memcmp(wire->magic, "DMBT0006", 8);
            if (wire->require_video_only && !wire->video_only) return false;
            wire->ble = !memcmp(wire->magic, "DMBT0005", 8);
            wire->control = wire->ble || !memcmp(wire->magic, "DMBT0004", 8);
            if (!wire->video_only && !wire->control && memcmp(wire->magic, "DMBT0003", 8)) {
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
            if ((wire->video_only && wire->type != 0 && wire->type != 1 && wire->type != 4)
                    || (wire->type == 0 && (!wire->remaining || wire->remaining > 16384))
                    || (wire->type == 1 && wire->remaining != 1)
                    || (wire->type == 2 && (!wire->control || !control || !wire->remaining || wire->remaining > 16384))
                    || (wire->type == 3 && (!wire->ble || !setup || wire->remaining != 32))
                    || (wire->type == 4 && (!wire->video_only || !wire->appearance || !wire->remaining || wire->remaining > 16384))
                    || wire->type > 4) return false;
        }
        size_t take = wire->remaining;
        if (take > length) take = length;
        if (!take) continue;
        if (wire->type == 0) { if (!video(context, bytes, take)) return false; }
        else if (wire->type == 4) { if (!wire->appearance(context, bytes, take)) return false; }
        else if (wire->type == 2) { if (!control(context, bytes, take)) return false; }
        else if (wire->type == 3) { if (!setup(context, bytes, take)) return false; }
        else {
            if (wire->video_only ? bytes[0] != 6 : (bytes[0] < 1 || bytes[0] > (wire->ble ? 8 : (wire->control ? 6 : 5)))) return false;
            event(context, bytes[0]);
        }
        wire->remaining -= (uint32_t)take; bytes += take; length -= take;
    }
    return true;
}
bool dm_classic_wire_feed_control(DMClassicWire *wire, const uint8_t *bytes, size_t length,
        DMWireVideo video, DMWireEvent event, DMWireVideo control, void *context) {
    return dm_classic_wire_feed_ble(wire, bytes, length, video, event, control, NULL, context);
}
bool dm_classic_wire_complete(const DMClassicWire *wire) {
    return wire->decided && (wire->legacy || (!wire->remaining && !wire->header_used));
}

bool dm_classic_wire_feed(DMClassicWire *wire, const uint8_t *bytes, size_t length,
    DMWireVideo video, DMWireEvent event, void *context) {
    return dm_classic_wire_feed_control(wire, bytes, length, video, event, NULL, context);
}
