#ifndef DM_BLE_INPUT_CRYPTO_H
#define DM_BLE_INPUT_CRYPTO_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct { uint8_t encryption[32], authentication[32]; } DMBleInputKeys;
void dm_ble_session_key(const uint8_t pairing[32], const uint8_t nonce[32], uint8_t session[32]);
void dm_ble_input_keys(const uint8_t session[32], DMBleInputKeys *keys);
void dm_ble_output_keys(const uint8_t session[32], DMBleInputKeys *keys);
void dm_ble_input_proof(const DMBleInputKeys *keys, const uint8_t challenge[16], uint8_t proof[32]);
void dm_ble_clock_proof(const DMBleInputKeys *keys, const uint8_t time[8], uint8_t proof[32]);
bool dm_ble_input_seal(const DMBleInputKeys *keys, uint64_t sequence,
    const uint8_t *plain, size_t length, uint8_t *packet);
bool dm_ble_input_open(const DMBleInputKeys *keys, uint64_t sequence,
    const uint8_t *packet, size_t length, uint8_t *plain);
#endif
