import java.lang.reflect.*;
import java.time.*;

/** Runs against the Pixel's real public MetricStyle API and the built APK, without installing it. */
public final class MetricClockDeviceTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        Class<?> styleClass=Class.forName("android.app.Notification$MetricStyle");
        Class<?> metricClass=Class.forName("android.app.Notification$Metric");
        Class<?> valueClass=Class.forName("android.app.Notification$Metric$MetricValue");
        Class<?> timeClass=Class.forName("android.app.Notification$Metric$TimeDifference");
        Class<?> parser=Class.forName("app.droidmirror.bluetooth.bridge.ActivityMetricClock");
        Object instance=parser.getField("INSTANCE").get(null);
        Method read=parser.getMethod("readStyle",Object.class,long.class,long.class);
        Object[] values={timeClass.getMethod("forStopwatch",long.class,int.class).invoke(null,70000L,2),
            timeClass.getMethod("forPausedStopwatch",Duration.class,int.class).invoke(null,Duration.ofMillis(45500),2),
            timeClass.getMethod("forStopwatch",Instant.class,int.class).invoke(null,Instant.ofEpochMilli(970000),2),
            timeClass.getMethod("forTimer",long.class,int.class).invoke(null,130000L,2),
            timeClass.getMethod("forPausedTimer",Duration.class,int.class).invoke(null,Duration.ofMillis(45500),2),
            timeClass.getMethod("forTimer",Instant.class,int.class).invoke(null,Instant.ofEpochMilli(1030000),2),
            timeClass.getMethod("forTimer",long.class,int.class).invoke(null,90000L,2)};
        for(int i=0;i<values.length;i++) {
            Object style=styleClass.getConstructor().newInstance();
            Object metric=metricClass.getConstructor(valueClass,CharSequence.class).newInstance(values[i],"Stopwatch");
            styleClass.getMethod("addMetric",metricClass).invoke(style,metric);
            Object result=read.invoke(instance,style,100000L,1000000L);
            check(result!=null);
            check(result.getClass().getMethod("getLabel").invoke(result).equals("Stopwatch"));
            check(result.getClass().getMethod("getCountDown").invoke(result).equals(i>=3));
            if(i==1 || i==4) check(result.getClass().getMethod("getPausedMs").invoke(result).equals(45500L));
            else check(result.getClass().getMethod("getBaseElapsedMs").invoke(result).equals(i<3 ? 70000L : i==6 ? 90000L : 130000L));
        }
        System.out.println("PASS: real Android 17 metric timers and stopwatches: running, paused, expired and monotonic/wall bases");
    }
}
