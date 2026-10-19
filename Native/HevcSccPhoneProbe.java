import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;

/** Enumerates HEVC encoder capabilities; never captures the screen or changes settings. */
public final class HevcSccPhoneProbe {
    public static void main(String[] args) throws Exception {
        System.out.println("Device: " + Build.MODEL + "; API " + Build.VERSION.SDK_INT);
        int encoders = 0;
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
            if (!info.isEncoder()) continue;
            boolean hevc = false;
            for (String mime : info.getSupportedTypes()) hevc |= MediaFormat.MIMETYPE_VIDEO_HEVC.equals(mime);
            if (!hevc) continue;
            ++encoders;
            System.out.println("HEVC encoder: " + info.getName());
            if (Build.VERSION.SDK_INT >= 29) System.out.println("  hardware=" + info.isHardwareAccelerated() + "; software=" + info.isSoftwareOnly());
            MediaCodecInfo.CodecCapabilities capabilities = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC);
            for (MediaCodecInfo.CodecProfileLevel profile : capabilities.profileLevels) {
                String name = "unrecognized";
                for (java.lang.reflect.Field field : MediaCodecInfo.CodecProfileLevel.class.getFields()) {
                    if (field.getName().startsWith("HEVCProfile") && field.getInt(null) == profile.profile) name = field.getName();
                }
                System.out.println("  profile=" + name + " (0x" + Integer.toHexString(profile.profile) + "); level=0x" + Integer.toHexString(profile.level));
            }
            if (Build.VERSION.SDK_INT >= 31) {
                MediaCodec codec = null;
                try {
                    codec = MediaCodec.createByCodecName(info.getName());
                    System.out.println("  vendor parameters: " + codec.getSupportedVendorParameters());
                } catch (Exception unavailable) {
                    System.out.println("  vendor parameter inspection unavailable: " + unavailable.getClass().getSimpleName());
                } finally { if (codec != null) codec.release(); }
            }
        }
        System.out.println("HEVC encoders inspected: " + encoders);
        System.out.println("Main, Main10 and MainStill are not HEVC Screen Content Coding profiles.");
        System.out.println("No vendor parameter name alone proves SCC; an emitted SCC bitstream and compatible decoder must be verified.");
    }
}
