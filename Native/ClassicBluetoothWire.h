#ifndef DM_CLASSIC_BLUETOOTH_WIRE_H
#define DM_CLASSIC_BLUETOOTH_WIRE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint8_t magic[8], header[5];
    size_t magic_used, header_used;
    uint32_t remaining;
    uint8_t type;
    bool decided, legacy, control;
} DMClassicWire;
typedef bool (*DMWireVideo)(void *, const uint8_t *, size_t);
typedef void (*DMWireEvent)(void *, uint8_t);
void dm_classic_wire_init(DMClassicWire *wire);
bool dm_classic_wire_feed(DMClassicWire *wire, const uint8_t *bytes, size_t length,
                          DMWireVideo video, DMWireEvent event, void *context);
bool dm_classic_wire_feed_control(DMClassicWire *wire, const uint8_t *bytes, size_t length,
    DMWireVideo video, DMWireEvent event, DMWireVideo control, void *context);
bool dm_classic_wire_complete(const DMClassicWire *wire);
#endif
