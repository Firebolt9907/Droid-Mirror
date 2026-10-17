import com.genymobile.scrcpy.model.ExactAspectRatio;
import java.util.Arrays;

public final class ExactAspectRatioTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        check(Arrays.equals(ExactAspectRatio.fit(1080,2400,1040,2,null),new int[]{468,1040}));
        check(Arrays.equals(ExactAspectRatio.fit(1080,2400,1920,2,null),new int[]{864,1920}));
        check(Arrays.equals(ExactAspectRatio.fit(1080,2400,0,2,null),new int[]{1080,2400}));
        // Even encoders requiring 16-pixel blocks must preserve the ratio.
        check(Arrays.equals(ExactAspectRatio.fit(1080,2400,1056,16,null),new int[]{432,960}));
        check(Arrays.equals(ExactAspectRatio.fit(1080,2400,0,16,null),new int[]{1008,2240}));
        check(Arrays.equals(ExactAspectRatio.fit(1080,2400,1920,2,(w,h)->h<=1280),new int[]{576,1280}));
        for (int[] source : new int[][]{{1080,2400},{2400,1080},{1080,2340},{1440,3120},{1920,1080},{320,640},{1280,1280}}) {
            for (int limit : new int[]{0,480,960,1040,1280,1920}) for (int alignment : new int[]{1,2,4,8,16}) {
                int[] size=ExactAspectRatio.fit(source[0],source[1],limit,alignment,null);
                check((long)size[0]*source[1]==(long)size[1]*source[0]);
                check(size[0]>0 && size[1]>0 && size[0]<=source[0] && size[1]<=source[1]);
                check(size[0]%alignment==0 && size[1]%alignment==0);
                check(limit==0 || Math.max(size[0],size[1])<=limit);
                // Compare against all legal aligned widths to verify maximality.
                for (int width=alignment;width<=source[0];width+=alignment) {
                    long numerator=(long)width*source[1];
                    if (numerator%source[0]!=0) continue;
                    long height=numerator/source[0];
                    if (height%alignment!=0 || height>source[1] || (limit>0 && Math.max(width,height)>limit)) continue;
                    check(width<=size[0]);
                }
            }
        }
        for (int[] invalid : new int[][]{{0,2400,1920,2},{1080,2400,-1,2},{1080,2400,1920,3},
                {1080,2400,100,16},{1081,2400,1920,2}}) {
            try { ExactAspectRatio.fit(invalid[0],invalid[1],invalid[2],invalid[3],null); throw new AssertionError(); }
            catch (IllegalArgumentException expected) {}
        }
        try { ExactAspectRatio.fit(1080,2400,1920,2,(w,h)->false); throw new AssertionError(); }
        catch (IllegalArgumentException expected) {}
        System.out.println("Exact aspect: native/limited resolutions, portrait/landscape, alignment, capability limits, maximality and impossible-size rejection passed");
    }
}
