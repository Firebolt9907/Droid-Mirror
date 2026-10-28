// AOA bulk transport. The existing pairing proof authenticates the resulting
// stream; USB identifiers are discovery hints, never authentication.
#include <libusb-1.0/libusb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>

typedef struct {
    libusb_context *usb;
    libusb_device_handle *device;
    int interface, listener, local;
    unsigned char input, output;
    atomic_bool stopped, connected;
    pthread_t worker;
} DMUsb;

static int dm_usb_accessory(uint16_t vendor, uint16_t product) {
    return vendor==0x18d1 && (product==0x2d00 || product==0x2d01 || product==0x2d04 || product==0x2d05);
}
static int dm_usb_android_vendor(uint16_t vendor) {
    switch (vendor) {
        case 0x18d1: case 0x04e8: case 0x22b8: case 0x0bb4:
        case 0x12d1: case 0x2717: case 0x2a70: case 0x1004:
        case 0x0fce: case 0x2d95: case 0x19d2: return 1;
        default: return 0;
    }
}
static int dm_usb_start_accessory(libusb_device_handle *device) {
    unsigned char protocol[2];
    if (libusb_control_transfer(device,0xc0,51,0,0,protocol,2,500)!=2 || !(protocol[0]|protocol[1])) return 0;
    const char *strings[]={"DroidMirror","DroidMirror USB","Authenticated screen video","1","","DroidMirror"};
    for (int i=0;i<6;i++) {
        size_t length=strlen(strings[i])+1;
        if (libusb_control_transfer(device,0x40,52,0,i,(unsigned char *)strings[i],length,500)!=(int)length) return 0;
    }
    return libusb_control_transfer(device,0x40,53,0,0,NULL,0,500)==0;
}
static int dm_usb_find(DMUsb *usb) {
    libusb_device **devices;
    ssize_t count=libusb_get_device_list(usb->usb,&devices);
    if (count<0) return 0;
    // Avoid changing the USB mode of an arbitrary phone when multiple are attached.
    int candidates=0;
    for (ssize_t i=0;i<count;i++) {
        struct libusb_device_descriptor d;
        if (!libusb_get_device_descriptor(devices[i],&d) && dm_usb_android_vendor(d.idVendor)) candidates++;
    }
    int found=0;
    for (ssize_t i=0;i<count && !found;i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(devices[i],&d) || !dm_usb_android_vendor(d.idVendor) || candidates!=1) continue;
        libusb_device_handle *device=NULL;
        if (libusb_open(devices[i],&device)) continue;
        if (!dm_usb_accessory(d.idVendor,d.idProduct)) {
            dm_usb_start_accessory(device); libusb_close(device); continue;
        }
        // AOA descriptor strings vary by Android vendor. Peer identity is
        // verified by the pairing proof after connecting the dedicated bulk lane.
        struct libusb_config_descriptor *config=NULL;
        if (!libusb_get_active_config_descriptor(devices[i],&config)) {
            for (int n=0;n<config->bNumInterfaces && !found;n++) {
                const struct libusb_interface_descriptor *iface=&config->interface[n].altsetting[0];
                unsigned char input=0,output=0;
                // Accessory interface only, never the adjacent ADB interface.
                if (iface->bInterfaceClass!=0xff || iface->bInterfaceSubClass!=0xff) continue;
                for (int e=0;e<iface->bNumEndpoints;e++) {
                    const struct libusb_endpoint_descriptor *ep=&iface->endpoint[e];
                    if ((ep->bmAttributes&3)!=LIBUSB_TRANSFER_TYPE_BULK) continue;
                    if (ep->bEndpointAddress&0x80) input=ep->bEndpointAddress;
                    else output=ep->bEndpointAddress;
                }
                if (input && output && !libusb_claim_interface(device,iface->bInterfaceNumber)) {
                    usb->device=device; usb->interface=iface->bInterfaceNumber;
                    usb->input=input; usb->output=output; found=1;
                }
            }
            libusb_free_config_descriptor(config);
        }
        if (!found) libusb_close(device);
    }
    libusb_free_device_list(devices,1);
    return found;
}
static int dm_usb_send(int fd,const unsigned char *bytes,int length) {
    while (length) {
        ssize_t n=send(fd,bytes,length,0);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return 0;
        bytes+=n; length-=n;
    }
    return 1;
}
static void *dm_usb_upload(void *context) {
    DMUsb *usb=context;
    unsigned char bytes[16384];
    while (!atomic_load(&usb->stopped)) {
        ssize_t n=recv(usb->local,bytes,sizeof(bytes),0);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) break;
        for (int offset=0;offset<n;) {
            int sent=0;
            int result=libusb_bulk_transfer(usb->device,usb->output,bytes+offset,(int)n-offset,&sent,1000);
            if (result || !sent) goto done;
            offset+=sent;
        }
    }
done:
    shutdown(usb->local,SHUT_RDWR);
    return NULL;
}
static void *dm_usb_run(void *context) {
    DMUsb *usb=context;
    while (!atomic_load(&usb->stopped)) {
        if (!dm_usb_find(usb)) { usleep(500000); continue; }
        atomic_store(&usb->connected,1);
        int local=accept(usb->listener,NULL,NULL);
        if (local>=0 && !atomic_load(&usb->stopped)) {
            usb->local=local;
            int yes=1; setsockopt(local,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
            struct timeval timeout={1,0}; setsockopt(local,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            pthread_t upload; int started=!pthread_create(&upload,NULL,dm_usb_upload,usb);
            unsigned char bytes[16384];
            while (started && !atomic_load(&usb->stopped)) {
                int received=0;
                int result=libusb_bulk_transfer(usb->device,usb->input,bytes,sizeof(bytes),&received,500);
                if (received && !dm_usb_send(local,bytes,received)) break;
                if (result && result!=LIBUSB_ERROR_TIMEOUT) break;
                // Observe closure by the uploader even while Android is idle.
                unsigned char probe;
                if (recv(local,&probe,1,MSG_PEEK|MSG_DONTWAIT)==0) break;
            }
            shutdown(local,SHUT_RDWR);
            if (started) pthread_join(upload,NULL);
        }
        if (local>=0) close(local);
        atomic_store(&usb->connected,0);
        libusb_release_interface(usb->device,usb->interface);
        libusb_close(usb->device); usb->device=NULL;
        usleep(500000);
    }
    return NULL;
}
void *dm_usb_start(uint16_t *port) {
    *port=0;
    DMUsb *usb=calloc(1,sizeof(*usb));
    if (!usb) return NULL;
    usb->listener=-1; usb->local=-1;
    if (libusb_init(&usb->usb)) { free(usb); return NULL; }
    usb->listener=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={0}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    socklen_t size=sizeof(address);
    if (usb->listener<0 || bind(usb->listener,(struct sockaddr *)&address,size) || listen(usb->listener,1)
        || getsockname(usb->listener,(struct sockaddr *)&address,&size) || pthread_create(&usb->worker,NULL,dm_usb_run,usb)) {
        if (usb->listener>=0) close(usb->listener);
        libusb_exit(usb->usb); free(usb); return NULL;
    }
    *port=ntohs(address.sin_port);
    return usb;
}
int dm_usb_connected(void *context) { return context && atomic_load(&((DMUsb *)context)->connected); }
void dm_usb_stop(void *context) {
    if (!context) return;
    DMUsb *usb=context; atomic_store(&usb->stopped,1);
    shutdown(usb->listener,SHUT_RDWR);
    pthread_join(usb->worker,NULL); close(usb->listener);
    libusb_exit(usb->usb); free(usb);
}
