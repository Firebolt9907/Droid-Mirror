#include <assert.h>
#include <stdio.h>
#include <libavformat/avformat.h>
#include "../scrcpy-5.0/app/src/hwdec.h"
#include "../scrcpy-5.0/app/src/texture.h"

static unsigned render_frames(AVCodecContext *ctx, AVFrame *frame,
                              struct sc_texture *texture, SDL_Renderer *renderer) {
    unsigned count = 0;
    while (avcodec_receive_frame(ctx, frame) == 0) {
        assert(frame->format == AV_PIX_FMT_VIDEOTOOLBOX);
        assert(sc_texture_update(texture, frame));
        assert(sc_texture_get(texture));
        SDL_RenderClear(renderer);
        assert(SDL_RenderTexture(renderer, sc_texture_get(texture), NULL, NULL));
        SDL_RenderPresent(renderer);
        av_frame_unref(frame); ++count;
    }
    return count;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(SDL_Init(SDL_INIT_VIDEO));
    SDL_SetHint("SDL_VIDEO_ACTIVATE_WHEN_SHOWN", "0");
    SDL_Window *window = SDL_CreateWindow("DroidMirror hidden hardware probe", 240, 533, SDL_WINDOW_HIDDEN);
    assert(window);
    SDL_Renderer *renderer = SDL_CreateRenderer(window, "metal");
    assert(renderer);
    struct sc_texture texture;
    assert(sc_texture_init(&texture, renderer, false, SC_HWDEC_MODE_VIDEOTOOLBOX));
    struct sc_hwdec hwdec;
    assert(sc_hwdec_init(&hwdec, sc_texture_get_hw_type(&texture), true, renderer));
    AVFormatContext *format = NULL;
    assert(avformat_open_input(&format, argv[1], NULL, NULL) == 0);
    assert(avformat_find_stream_info(format, NULL) >= 0);
    int index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    assert(index >= 0);
    AVCodecParameters *params = format->streams[index]->codecpar;
    const AVCodec *codec = sc_hwdec_find_decoder(&hwdec, params->codec_id);
    assert(codec);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    assert(ctx && avcodec_parameters_to_context(ctx, params) == 0);
    assert(sc_hwdec_configure(&hwdec, ctx));
    assert(avcodec_open2(ctx, codec, NULL) == 0);
    AVPacket *packet = av_packet_alloc(); AVFrame *frame = av_frame_alloc();
    assert(packet && frame);
    unsigned count = 0;
    while (av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == index) {
            assert(avcodec_send_packet(ctx, packet) >= 0);
            count += render_frames(ctx, frame, &texture, renderer);
        }
        av_packet_unref(packet);
    }
    assert(avcodec_send_packet(ctx, NULL) >= 0);
    count += render_frames(ctx, frame, &texture, renderer);
    assert(count > 0);
    printf("PASS: %u hardware-decoded H.265 frames imported into Metal using scrcpy 5.0's actual hardware/texture code\n", count);
    sc_texture_destroy(&texture); sc_hwdec_destroy(&hwdec);
    av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&ctx);
    avformat_close_input(&format);
    SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit();
}
