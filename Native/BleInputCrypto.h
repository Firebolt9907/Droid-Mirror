#ifndef DM_BLE_INPUT_CRYPTO_H
#define DM_BLE_INPUT_CRYPTO_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct { uint8_t encryption[32], authentication[32]; } DMBleInputKeys;
void dm_ble_input_keys(const uint8_t session[32], DMBleInputKeys *keys);
void dm_ble_input_proof(const DMBleInputKeys *keys, const uint8_t challenge[16], uint8_t proof[32]);
bool dm_ble_input_seal(const DMBleInputKeys *keys, uint64_t sequence,
    const uint8_t *plain, size_t length, uint8_t *packet);
#endif
