#define libusb_control_transfer mock_control_transfer
#define libusb_get_device_list mock_get_device_list
#define libusb_get_device_descriptor mock_get_device_descriptor
#define libusb_open mock_open
#define libusb_close mock_close
#define libusb_free_device_list mock_free_device_list
#define libusb_get_active_config_descriptor mock_get_config
#define libusb_free_config_descriptor mock_free_config
#define libusb_claim_interface mock_claim
#define libusb_bulk_transfer mock_bulk_transfer
#include "UsbAccessoryTransport.c"
#include <assert.h>
#include <stdio.h>

static int requests, strings, protocol=2, reject_string=-1, count=1, claims;
static int accessory_mode;
static unsigned char uploaded[32768];
static size_t uploaded_length;
static libusb_device *fake_devices[]={ (void *)1,(void *)2,NULL };
int mock_control_transfer(libusb_device_handle *device,uint8_t type,uint8_t request,uint16_t value,uint16_t index,
        unsigned char *data,uint16_t length,unsigned int timeout) {
    (void)device; (void)value; assert(timeout==500); requests++;
    if (request==51) { assert(type==0xc0 && length==2); data[0]=protocol; data[1]=0; return 2; }
    if (request==52) {
        assert(type==0x40 && index<6 && data[length-1]==0);
        if (index==0) assert(!strcmp((char *)data,"DroidMirror"));
        if (index==1) assert(!strcmp((char *)data,"DroidMirror USB"));
        strings++; return index==reject_string ? -1 : length;
    }
    assert(request==53 && type==0x40 && !length); return 0;
}
ssize_t mock_get_device_list(libusb_context *context,libusb_device ***list) { (void)context; *list=fake_devices; return count; }
int mock_get_device_descriptor(libusb_device *device,struct libusb_device_descriptor *descriptor) {
    (void)device; memset(descriptor,0,sizeof(*descriptor)); descriptor->idVendor=0x18d1;
    descriptor->idProduct=accessory_mode ? 0x2d01 : 0x4ee1; return 0;
}
int mock_open(libusb_device *device,libusb_device_handle **handle) { (void)device; *handle=(void *)3; return 0; }
void mock_close(libusb_device_handle *handle) { (void)handle; }
void mock_free_device_list(libusb_device **list,int unref) { (void)list; (void)unref; }
static struct libusb_endpoint_descriptor endpoints[]={
    {.bEndpointAddress=0x81,.bmAttributes=2}, {.bEndpointAddress=2,.bmAttributes=2}
};
static struct libusb_interface_descriptor interfaces[]={
    {.bInterfaceNumber=1,.bInterfaceClass=0xff,.bInterfaceSubClass=0x42,.bNumEndpoints=2,.endpoint=endpoints},
    {.bInterfaceNumber=0,.bInterfaceClass=0xff,.bInterfaceSubClass=0xff,.bNumEndpoints=2,.endpoint=endpoints}
};
static struct libusb_interface interface_list[]={ {.altsetting=&interfaces[0],.num_altsetting=1}, {.altsetting=&interfaces[1],.num_altsetting=1} };
static struct libusb_config_descriptor config={.bNumInterfaces=2,.interface=interface_list};
int mock_get_config(libusb_device *device,struct libusb_config_descriptor **result) { (void)device; *result=&config; return 0; }
void mock_free_config(struct libusb_config_descriptor *descriptor) { (void)descriptor; }
int mock_claim(libusb_device_handle *device,int interface) { (void)device; assert(interface==0); claims++; return 0; }
int mock_bulk_transfer(libusb_device_handle *device,unsigned char endpoint,unsigned char *data,int length,int *sent,unsigned int timeout) {
    (void)device; assert(endpoint==2 && timeout==1000);
    *sent=length>511 ? 511 : length;
    assert(uploaded_length+*sent<=sizeof(uploaded));
    memcpy(uploaded+uploaded_length,data,*sent); uploaded_length+=*sent; return 0;
}
int main(void) {
    assert(dm_usb_android_vendor(0x18d1) && !dm_usb_android_vendor(0x05ac));
    assert(dm_usb_accessory(0x18d1,0x2d01) && !dm_usb_accessory(0x18d1,0x2d03));
    assert(dm_usb_start_accessory((void *)1) && requests==8 && strings==6);
    requests=strings=0; protocol=0;
    assert(!dm_usb_start_accessory((void *)1) && requests==1 && strings==0);
    protocol=2; reject_string=2; requests=strings=0;
    assert(!dm_usb_start_accessory((void *)1) && requests==4);
    reject_string=-1; requests=0; DMUsb usb={0}; count=2;
    assert(!dm_usb_find(&usb) && requests==0 && claims==0);
    count=1; accessory_mode=1;
    assert(dm_usb_find(&usb) && claims==1 && usb.input==0x81 && usb.output==2 && usb.interface==0);
    int sockets[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets)); usb.local=sockets[0];
    unsigned char payload[20000]; for (size_t i=0;i<sizeof(payload);i++) payload[i]=(unsigned char)i;
    pthread_t upload; assert(!pthread_create(&upload,NULL,dm_usb_upload,&usb));
    assert(dm_usb_send(sockets[1],payload,sizeof(payload))); shutdown(sockets[1],SHUT_WR);
    pthread_join(upload,NULL); close(sockets[0]); close(sockets[1]);
    assert(uploaded_length==sizeof(payload) && !memcmp(uploaded,payload,sizeof(payload)));
    puts("USB AOA: no-ADB negotiation, unsupported devices, failed setup, multiple-phone ambiguity, ADB-interface isolation and partial bulk writes passed");
}
