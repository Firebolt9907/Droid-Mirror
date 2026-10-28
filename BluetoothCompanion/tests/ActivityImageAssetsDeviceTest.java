import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.ShapeDrawable;
import android.graphics.drawable.shapes.OvalShape;
import java.util.*;
import java.lang.reflect.*;

/** Exercises Android's actual drawable renderer and PNG codec without posting notifications. */
public final class ActivityImageAssetsDeviceTest {
    static void check(boolean ok) { if(!ok) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        Class<?> type=Class.forName("app.droidmirror.bluetooth.bridge.ActivityImageAssets");
        Object assets=type.getConstructor().newInstance();
        ShapeDrawable drawing=new ShapeDrawable(new OvalShape());
        drawing.setIntrinsicWidth(24); drawing.setIntrinsicHeight(24);
        drawing.getPaint().setColor(Color.rgb(255,128,160));
        Method encode=type.getMethod("encode",Drawable.class,String.class);
        byte[] png=(byte[])encode.invoke(assets,drawing,"appIcon");
        check(png!=null && png[0]==(byte)137 && png[1]==80 && png[2]==78 && png[3]==71);
        Bitmap decoded=BitmapFactory.decodeByteArray(png,0,png.length);
        check(decoded.getWidth()==96 && decoded.getHeight()==96);
        check(decoded.getPixel(48,48)==Color.rgb(255,128,160));
        decoded.recycle();
        byte[] avatar=(byte[])encode.invoke(assets,drawing,"contactImage");
        check(avatar[0]==(byte)137); // Drawings remain lossless even in the avatar slot.
        decoded=BitmapFactory.decodeByteArray(avatar,0,avatar.length);
        check(decoded.getWidth()==160 && decoded.getPixel(80,80)==Color.rgb(255,128,160)); decoded.recycle();
        String hash=(String)type.getMethod("remember",byte[].class).invoke(assets,(Object)png);
        check(hash.equals(type.getMethod("remember",byte[].class).invoke(assets,(Object)png)));
        Method chunk=type.getMethod("chunk",String.class,int.class);
        check(chunk.invoke(assets,hash,1)==null);
        java.io.ByteArrayOutputStream assembled=new java.io.ByteArrayOutputStream();
        for(int offset=0;offset<png.length;offset+=768) {
            org.json.JSONObject packet=(org.json.JSONObject)chunk.invoke(assets,hash,offset);
            check(packet.getInt("offset")==offset && packet.getInt("total")==png.length);
            assembled.write(android.util.Base64.decode(packet.getString("data"),android.util.Base64.NO_WRAP));
        }
        check(Arrays.equals(assembled.toByteArray(),png));
        System.out.println("PASS: lossless 96px drawable icons, 160px avatars, exact colors, hashes and bounded chunks");
    }
}
