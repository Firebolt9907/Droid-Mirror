import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.video.VideoConstraints;
import com.genymobile.scrcpy.video.VideoFilter;

public final class CaptureGeometryTest {
    public static void main(String[] args) {
        for (Size source : new Size[]{new Size(1080, 2400), new Size(2400, 1080)}) {
            Size encoded = source.constrain(new VideoConstraints(1056, 16, null));
            VideoFilter filter = new VideoFilter(source);
            filter.addResizeIfAspectRatioChanged(encoded);
            if (filter.getInverseTransform() != null) {
                throw new AssertionError("Exact-ratio capture must not need compensating GL stretch");
            }
            if ((long)source.getWidth()*encoded.getHeight() != (long)source.getHeight()*encoded.getWidth()) {
                throw new AssertionError("Encoder alignment changed the phone aspect ratio");
            }
            if (encoded.getWidth()%16 != 0 || encoded.getHeight()%16 != 0 || encoded.getMax()>1056) {
                throw new AssertionError("Exact-ratio size violated encoder constraints");
            }
        }
        VideoFilter exact = new VideoFilter(new Size(1080, 2400));
        exact.addResizeIfAspectRatioChanged(new Size(432, 960));
        if (exact.getInverseTransform() != null) throw new AssertionError("Exact aspect ratios need no GL pass");
        System.out.println("PASS: portrait/landscape alignment preserves the phone aspect ratio without a compensating GL pass");
    }
}
