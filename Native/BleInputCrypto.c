#include "BleInputCrypto.h"
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonCryptor.h>
#include <string.h>
void dm_ble_input_keys(const uint8_t session[32], DMBleInputKeys *keys) {
    const char enc[]="DroidMirror BLE encryption v1", auth[]="DroidMirror BLE authentication v1";
    CCHmac(kCCHmacAlgSHA256,session,32,enc,sizeof(enc)-1,keys->encryption);
    CCHmac(kCCHmacAlgSHA256,session,32,auth,sizeof(auth)-1,keys->authentication);
}
void dm_ble_input_proof(const DMBleInputKeys *keys, const uint8_t challenge[16], uint8_t proof[32]) {
    const char label[]="DroidMirror BLE proof v1";
    uint8_t data[sizeof(label)-1+16];memcpy(data,label,sizeof(label)-1);memcpy(data+sizeof(label)-1,challenge,16);
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
