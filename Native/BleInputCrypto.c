#include "BleInputCrypto.h"
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonCryptor.h>
#include <string.h>
void dm_ble_session_key(const uint8_t pairing[32], const uint8_t nonce[32], uint8_t session[32]) {
    const char label[]="DroidMirror BLE session v1";
    uint8_t data[sizeof(label)-1+32]; memcpy(data,label,sizeof(label)-1); memcpy(data+sizeof(label)-1,nonce,32);
    CCHmac(kCCHmacAlgSHA256,pairing,32,data,sizeof(data),session);
}
void dm_ble_input_keys(const uint8_t session[32], DMBleInputKeys *keys) {
    const char enc[]="DroidMirror BLE encryption v1", auth[]="DroidMirror BLE authentication v1";
    CCHmac(kCCHmacAlgSHA256,session,32,enc,sizeof(enc)-1,keys->encryption);
    CCHmac(kCCHmacAlgSHA256,session,32,auth,sizeof(auth)-1,keys->authentication);
}
void dm_ble_output_keys(const uint8_t session[32], DMBleInputKeys *keys) {
    const char enc[]="DroidMirror BLE return encryption v1", auth[]="DroidMirror BLE return authentication v1";
    CCHmac(kCCHmacAlgSHA256,session,32,enc,sizeof(enc)-1,keys->encryption);
    CCHmac(kCCHmacAlgSHA256,session,32,auth,sizeof(auth)-1,keys->authentication);
}
void dm_ble_input_proof(const DMBleInputKeys *keys, const uint8_t challenge[16], uint8_t proof[32]) {
    const char label[]="DroidMirror BLE proof v1";
    uint8_t data[sizeof(label)-1+16];memcpy(data,label,sizeof(label)-1);memcpy(data+sizeof(label)-1,challenge,16);
    CCHmac(kCCHmacAlgSHA256,keys->authentication,32,data,sizeof(data),proof);
}
void dm_ble_clock_proof(const DMBleInputKeys *keys, const uint8_t time[8], uint8_t proof[32]) {
    const char label[]="DroidMirror BLE clock v1";
    uint8_t data[sizeof(label)-1+8]; memcpy(data,label,sizeof(label)-1); memcpy(data+sizeof(label)-1,time,8);
    CCHmac(kCCHmacAlgSHA256,keys->authentication,32,data,sizeof(data),proof);
}
bool dm_ble_input_seal(const DMBleInputKeys *keys, uint64_t sequence,
        const uint8_t *plain, size_t length, uint8_t *packet) {
    if (!sequence || sequence >= INT64_MAX || !length || length > 488) return false;
    uint8_t iv[16]="DMINPUT1", tag[32];
    for(int i=0;i<8;++i) packet[i]=iv[8+i]=(uint8_t)(sequence>>(56-i*8));
    CCCryptorRef cipher=NULL;
    if(CCCryptorCreateWithMode(kCCEncrypt,kCCModeCTR,kCCAlgorithmAES,ccNoPadding,iv,
            keys->encryption,32,NULL,0,0,kCCModeOptionCTR_BE,&cipher)!=kCCSuccess) return false;
    size_t written=0;
    CCCryptorStatus status=CCCryptorUpdate(cipher,plain,length,packet+8,length,&written);
    CCCryptorRelease(cipher);
    if(status!=kCCSuccess || written!=length) return false;
    CCHmac(kCCHmacAlgSHA256,keys->authentication,32,packet,length+8,tag);
    memcpy(packet+length+8,tag,16); return true;
}
bool dm_ble_input_open(const DMBleInputKeys *keys, uint64_t sequence,
        const uint8_t *packet, size_t length, uint8_t *plain) {
    if (!sequence || sequence >= INT64_MAX || length <= 24 || length > 512) return false;
    uint64_t received=0;
    for (int i=0;i<8;++i) received=(received<<8)|packet[i];
    if (received != sequence) return false;
    uint8_t tag[32], difference=0;
    CCHmac(kCCHmacAlgSHA256,keys->authentication,32,packet,length-16,tag);
    for (int i=0;i<16;++i) difference |= tag[i]^packet[length-16+i];
    if (difference) return false;
    uint8_t iv[16]="DMINPUT1"; memcpy(iv+8,packet,8);
    CCCryptorRef cipher=NULL;
    if(CCCryptorCreateWithMode(kCCDecrypt,kCCModeCTR,kCCAlgorithmAES,ccNoPadding,iv,
            keys->encryption,32,NULL,0,0,kCCModeOptionCTR_BE,&cipher)!=kCCSuccess) return false;
    size_t written=0;
    CCCryptorStatus status=CCCryptorUpdate(cipher,packet+8,length-24,plain,length-24,&written);
    CCCryptorRelease(cipher);
    return status==kCCSuccess && written==length-24;
}
