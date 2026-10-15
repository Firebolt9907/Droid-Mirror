#include "BleInputCrypto.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void hex(const uint8_t *bytes,size_t length,char *output) {
    for(size_t i=0;i<length;++i) snprintf(output+i*2,3,"%02x",bytes[i]);
}
int main(int argc,char **argv) {
    uint8_t session[32],challenge[16],plain[488]={1,0,0,0,8},packet[512],proof[32]; char output[1025];
    for(int i=0;i<32;++i) session[i]=(uint8_t)i;
    DMBleInputKeys keys; dm_ble_input_keys(session,&keys); for(int i=0;i<16;++i) challenge[i]=(uint8_t)i; dm_ble_input_proof(&keys,challenge,proof);
    hex(proof,32,output); assert(!strcmp(output,"eaa36a8dcfebabd9da451687a4e0091f469c869592241b5ea604cef6a99ccd8d"));
    assert(dm_ble_input_seal(&keys,1,plain,13,packet)); hex(packet,37,output);
    // Independently generated with OpenSSL AES-256-CTR and Python HMAC-SHA256.
    assert(!strcmp(output,"00000000000000016b4316245fe8d792ac5a72baf629fb8da00e9d50e02624cd2e99feb996"));
    assert(!dm_ble_input_seal(&keys,0,plain,13,packet));
    assert(!dm_ble_input_seal(&keys,1,plain,0,packet));
    assert(!dm_ble_input_seal(&keys,1,plain,489,packet));
    if(argc==2) {
        FILE *file=fopen(argv[1],"wb"); assert(file);
        const size_t lengths[]={1,181,488};
        for(size_t i=0;i<3;++i) {
            for(size_t j=0;j<lengths[i];++j) plain[j]=(uint8_t)(j+i);
            assert(dm_ble_input_seal(&keys,i+1,plain,lengths[i],packet));
            uint16_t size=(uint16_t)(lengths[i]+24); fputc(size>>8,file); fputc(size&255,file);
            assert(fwrite(packet,1,size,file)==size);
        }
        fclose(file);
    }
    puts("BLE input crypto: independent vector, proof and record bounds passed");
}
