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
    uint8_t notification[32]; dm_ble_notification_pairing_key(session, notification); hex(notification, 32, output);
    assert(!strcmp(output, "612462f4f9c5c73d3d61fca80066dd8f099333d036948bdc116a3cb7d2fcf17b"));
    assert(memcmp(session, notification, 32));
    uint8_t derived[32]; dm_ble_session_key(session,session,derived); hex(derived,32,output);
    assert(!strcmp(output,"7b06af8f972ce57eea27ba74bbdf6d1f6114e67d71b6eb05a17459f282840200"));
    DMBleInputKeys keys; dm_ble_input_keys(session,&keys); for(int i=0;i<16;++i) challenge[i]=(uint8_t)i; dm_ble_input_proof(&keys,challenge,proof);
    hex(proof,32,output); assert(!strcmp(output,"eaa36a8dcfebabd9da451687a4e0091f469c869592241b5ea604cef6a99ccd8d"));
    uint8_t clockTime[8]={0,0,0,0,7,91,205,21}; dm_ble_clock_proof(&keys,clockTime,proof);
    hex(proof,32,output); assert(!strcmp(output,"1161d2415df57690a9d16aef9a8cb69b0fe65629616d147120b08bb6d300af21"));
    uint8_t nextInput[8]={0,0,0,0,0,0,0,1}; dm_ble_resume_proof(&keys,challenge,nextInput,proof);
    hex(proof,32,output); assert(!strcmp(output,"bebdb9e5b2a010c52e61baa7667d5a4d113392dd31f7991366d4a7ace3edf7f4"));
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
    if(argc==3) {
        FILE *file=fopen(argv[2],"rb"); assert(file);
        DMBleInputKeys returning; dm_ble_output_keys(session,&returning);
        uint64_t sequence=1;
        while (true) {
            int high=fgetc(file); if (high==EOF) break;
            int low=fgetc(file); assert(low!=EOF);
            size_t length=(size_t)(high*256+low); assert(length>24 && length<=sizeof(packet));
            assert(fread(packet,1,length,file)==length);
            uint8_t decoded[488];
            assert(!dm_ble_input_open(&keys,sequence,packet,length,decoded));
            assert(!dm_ble_input_open(&returning,sequence+1,packet,length,decoded));
            packet[length-1]^=1; assert(!dm_ble_input_open(&returning,sequence,packet,length,decoded)); packet[length-1]^=1;
            assert(dm_ble_input_open(&returning,sequence,packet,length,decoded));
            for (size_t i=0;i<length-24;++i) assert(decoded[i]==(uint8_t)i);
            ++sequence;
        }
        assert(sequence==4); fclose(file);
        puts("Java-to-Mac return crypto: directional isolation, tamper, ordering and payloads passed");
    }
    puts("BLE input crypto: independent vector, proof and record bounds passed");
}
