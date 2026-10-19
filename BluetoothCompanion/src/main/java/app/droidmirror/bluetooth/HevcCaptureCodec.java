package app.droidmirror.bluetooth;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import java.io.IOException;

/** Selects regular 8-bit HEVC for the hybrid stream; never substitutes AVC or SCC. */
final class HevcCaptureCodec {
    final String name;
    private final int bitRateMode;
    private final boolean intraRefresh;

    private HevcCaptureCodec(String name, int bitRateMode, boolean intraRefresh) {
        this.name=name; this.bitRateMode=bitRateMode; this.intraRefresh=intraRefresh;
    }

    static HevcCaptureCodec select() throws IOException {
        MediaCodecInfo[] codecs=new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos();
        // Prefer hardware, retaining only HEVC as a software option on devices
        // without a usable hardware surface encoder. No H.264 fallback.
        for (int pass=0;pass<2;pass++) for (MediaCodecInfo codec : codecs) {
            if (!codec.isEncoder()) continue;
            if (Build.VERSION.SDK_INT>=29 && codec.isHardwareAccelerated()!=(pass==0)) continue;
            for (String mime : codec.getSupportedTypes()) {
                if (!MediaFormat.MIMETYPE_VIDEO_HEVC.equals(mime)) continue;
                try {
                    MediaCodecInfo.CodecCapabilities caps=codec.getCapabilitiesForType(mime);
                    boolean surface=false, main=false;
                    for (int color : caps.colorFormats) surface |= color==MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface;
                    for (MediaCodecInfo.CodecProfileLevel profile : caps.profileLevels)
                        main |= profile.profile==MediaCodecInfo.CodecProfileLevel.HEVCProfileMain;
                    MediaCodecInfo.EncoderCapabilities encoder=caps.getEncoderCapabilities();
                    int mode=HevcCapturePolicy.bitRateMode(
                        encoder.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR),
                        encoder.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR));
                    if (surface && main && mode>=0)
                        return new HevcCaptureCodec(codec.getName(),mode,
                            caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_IntraRefresh));
                } catch (IllegalArgumentException unavailable) { /* Try the next HEVC implementation. */ }
            }
        }
        throw new IOException("HEVC capture unavailable: no Main-profile surface encoder with bitrate control");
    }

    String bluetoothOptions() { return HevcCapturePolicy.bluetoothOptions(bitRateMode,intraRefresh); }
}
