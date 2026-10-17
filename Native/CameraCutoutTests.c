#include "camera_cutout.h"
#include "device_msg.h"
#include "control_msg.h"
#include "events.h"
#include "util/binary.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

#ifdef __APPLE__
static unsigned native_count;
static float native_circles[16];
void DroidMirrorSetCameraCutouts(SDL_Window *window, const float *circles, unsigned count) {
    (void) window;
    native_count = count;
    for (unsigned i = 0; i < count * 4; ++i) native_circles[i] = circles[i];
}
#endif

static void near(float a, float b) { assert(fabsf(a-b) < .01f); }
static uint8_t red(SDL_Surface *surface, int x, int y) {
    uint8_t r, g, b, a;
    assert(SDL_ReadSurfacePixel(surface,x,y,&r,&g,&b,&a));
    return r;
}
int main(void) {
    assert(SDL_Init(SDL_INIT_EVENTS));
    struct sc_camera_cutout data = {.width=1080,.height=2400,.count=1,.rects={{503,29,576,103}}};
    SDL_FRect content={20,10,540,1200};
    SDL_FPoint center;
    float radius;
    assert(sc_camera_cutout_circle(&data.rects[0],&data,&content,SC_ORIENTATION_0,&center,&radius));
    near(center.x,289.75f); near(center.y,43); near(radius,18.25f);
    SDL_FRect landscape={10,20,1200,540};
    assert(sc_camera_cutout_circle(&data.rects[0],&data,&landscape,SC_ORIENTATION_90,&center,&radius));
    near(center.x,1177); near(center.y,289.75); near(radius,18.25f);
    assert(sc_camera_cutout_circle(&data.rects[0],&data,&content,SC_ORIENTATION_180,&center,&radius));
    near(center.x,290.25); near(center.y,1177);
    assert(sc_camera_cutout_circle(&data.rects[0],&data,&landscape,SC_ORIENTATION_270,&center,&radius));
    near(center.x,43); near(center.y,290.25);
    assert(sc_camera_cutout_circle(&data.rects[0],&data,&content,SC_ORIENTATION_FLIP_0,&center,&radius));
    near(center.x,290.25); near(center.y,43);

    SDL_Surface *surface=SDL_CreateSurface(580,1220,SDL_PIXELFORMAT_RGBA32);
    SDL_Renderer *renderer=SDL_CreateSoftwareRenderer(surface);
    assert(surface && renderer);
    SDL_SetRenderDrawColor(renderer,255,255,255,255);
    SDL_RenderClear(renderer);
    sc_camera_cutout_set(&data);
    SDL_Event update;
    assert(SDL_PeepEvents(&update,1,SDL_GETEVENT,SC_EVENT_CAMERA_CUTOUT_UPDATED,SC_EVENT_CAMERA_CUTOUT_UPDATED)==1);
    assert(sc_camera_cutout_matches_frame((struct sc_size){1080,2400}));
    assert(!sc_camera_cutout_matches_frame((struct sc_size){864,1920}));
#ifdef __APPLE__
    sc_camera_cutout_update_window(renderer,&content,(struct sc_size){1080,2400},SC_ORIENTATION_0);
    assert(native_count == 1);
    near(native_circles[0],289.75f/580); near(native_circles[1],43.0f/1220);
    near(native_circles[2],18.25f/580); near(native_circles[3],18.25f/1220);
    sc_camera_cutout_update_window(renderer,&landscape,(struct sc_size){1080,2400},SC_ORIENTATION_90);
    assert(native_count == 1);
    near(native_circles[0],1177.0f/580); near(native_circles[1],289.75f/1220);
    sc_camera_cutout_update_window(renderer,&content,(struct sc_size){2400,1080},SC_ORIENTATION_0);
    assert(native_count == 0);
    sc_camera_cutout_update_window(renderer,&content,(struct sc_size){0,0},SC_ORIENTATION_0);
    assert(native_count == 0);
#endif
    sc_camera_cutout_render(renderer,&content,(struct sc_size){1080,2400},SC_ORIENTATION_0);
    SDL_RenderPresent(renderer);
    assert(red(surface,290,43)==0); // circle center
    assert(red(surface,273,27)==255); // bounding rectangle corner stays visible
    assert(red(surface,290,20)==255); // no padded status-bar masking
    assert(red(surface,10,43)==255); // letterbox untouched
    assert(SDL_SaveBMP(surface,"/tmp/droidmirror-camera-preview.bmp"));
    SDL_SetRenderDrawColor(renderer,255,255,255,255); SDL_RenderClear(renderer);
    sc_camera_cutout_render(renderer,&content,(struct sc_size){2400,1080},SC_ORIENTATION_0);
    SDL_RenderPresent(renderer);
    assert(red(surface,290,43)==255); // stale rotation metadata hidden
    // Bluetooth -> LAN/ADB -> Bluetooth quality changes: delayed metadata must
    // wake the renderer without waiting for another encoded frame.
    const struct sc_size transitions[]={{144,320},{864,1920},{144,320},{576,1280}};
    for (unsigned i=0;i<sizeof(transitions)/sizeof(transitions[0]);++i) {
        struct sc_size frame=transitions[i];
        assert(!sc_camera_cutout_matches_frame(frame));
        struct sc_camera_cutout resized=data;
        resized.width=frame.width; resized.height=frame.height;
        resized.rects[0]=(struct sc_cutout_rect){
            503*frame.width/1080,29*frame.height/2400,
            576*frame.width/1080,103*frame.height/2400};
        sc_camera_cutout_set(&resized);
        assert(SDL_PeepEvents(&update,1,SDL_GETEVENT,SC_EVENT_CAMERA_CUTOUT_UPDATED,SC_EVENT_CAMERA_CUTOUT_UPDATED)==1);
        assert(sc_camera_cutout_matches_frame(frame));
        SDL_SetRenderDrawColor(renderer,255,255,255,255); SDL_RenderClear(renderer);
        sc_camera_cutout_render(renderer,&content,frame,SC_ORIENTATION_0);
        SDL_RenderPresent(renderer);
        assert(red(surface,290,43)==0);
    }
    struct sc_camera_cutout absent={.width=576,.height=1280,.count=0};
    sc_camera_cutout_set(&absent);
    assert(sc_camera_cutout_matches_frame((struct sc_size){576,1280}));
    sc_camera_cutout_set(NULL);
    assert(!sc_camera_cutout_matches_frame((struct sc_size){576,1280}));
    SDL_SetRenderDrawColor(renderer,255,255,255,255); SDL_RenderClear(renderer);
#ifdef __APPLE__
    sc_camera_cutout_update_window(renderer,&content,(struct sc_size){1080,2400},SC_ORIENTATION_0);
    assert(native_count == 0);
#endif
    sc_camera_cutout_render(renderer,&content,(struct sc_size){1080,2400},SC_ORIENTATION_0);
    SDL_RenderPresent(renderer);
    assert(red(surface,290,43)==255); // no camera means no invented hole
    SDL_DestroyRenderer(renderer); SDL_DestroySurface(surface);

    uint8_t bytes[22]={3,4,56,9,96,1}; // 1080x2400, one rectangle
    sc_write32be(bytes+6,503); sc_write32be(bytes+10,29);
    sc_write32be(bytes+14,576); sc_write32be(bytes+18,103);
    struct sc_device_msg msg;
    for (unsigned n=0;n<sizeof(bytes);++n) assert(sc_device_msg_deserialize(bytes,n,&msg)==0);
    assert(sc_device_msg_deserialize(bytes,sizeof(bytes),&msg)==22);
    assert(msg.camera_cutout.count==1 && msg.camera_cutout.rects[0].left==503);
    sc_device_msg_destroy(&msg);
    bytes[5]=5; assert(sc_device_msg_deserialize(bytes,sizeof(bytes),&msg)==-1);
    bytes[5]=1; sc_write32be(bytes+14,500); assert(sc_device_msg_deserialize(bytes,sizeof(bytes),&msg)==-1);
    struct sc_control_msg request={.type=SC_CONTROL_MSG_TYPE_GET_CAMERA_CUTOUT};
    assert(sc_control_msg_serialize(&request,bytes)==1 && bytes[0]==25);
    SDL_Quit();
    puts("PASS: circular pixels, accurate bounds, rotation/mirroring, letterboxing, stale/absent geometry, delayed handoff metadata redraw, fragmented/invalid messages and opt-in request");
}
