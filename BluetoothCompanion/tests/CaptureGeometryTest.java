import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.AffineMatrix;
import com.genymobile.scrcpy.video.VideoConstraints;
import com.genymobile.scrcpy.video.VideoFilter;

public final class CaptureGeometryTest {
    public static void main(String[] args) {
        for (Size source : new Size[]{new Size(1080, 2400), new Size(2400, 1080)}) {
            Size encoded = source.constrain(new VideoConstraints(1056, 16, null));
            VideoFilter filter = new VideoFilter(source);
            filter.addResizeIfAspectRatioChanged(encoded);
            if (!filter.getOutputSize().equals(encoded) || filter.getInverseTransform() == null) {
                throw new AssertionError("Aligned capture must use GL instead of a letterboxed virtual display");
            }
            // Identity UV mapping retains the full phone screen: no crop or padding.
            float[] actual = filter.getInverseTransform().to4x4();
            float[] expected = AffineMatrix.IDENTITY.to4x4();
            for (int i = 0; i < actual.length; ++i) {
                if (Math.abs(actual[i] - expected[i]) > 0.000001f) {
                    throw new AssertionError("Alignment must preserve the full source image");
                }
            }
        }
        VideoFilter exact = new VideoFilter(new Size(1080, 2400));
        exact.addResizeIfAspectRatioChanged(new Size(432, 960));
        if (exact.getInverseTransform() != null) throw new AssertionError("Exact aspect ratios need no GL pass");
        System.out.println("PASS: portrait/landscape alignment fills the encoder surface; exact ratios retain direct capture");
    }
}
