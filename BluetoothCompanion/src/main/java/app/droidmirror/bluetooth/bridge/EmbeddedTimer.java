package app.droidmirror.bluetooth.bridge;

import java.util.*;
import java.util.regex.*;

/** Recognize clock-shaped values by public metadata or observed unit-rate movement, never prose. */
public final class EmbeddedTimer {
    private static final Pattern CLOCK = Pattern.compile("(?<![\\d:])(?:\\d{1,3}:[0-5]\\d|\\d{1,3}):[0-5]\\d(?![\\d:])");
    private static final Pattern NUMBERS = Pattern.compile("\\d+(?:[:.,]\\d+)*");
    public static final class Span {
        public final int start, end; public final String token; public final double seconds; public final boolean down; public final String rounding;
        Span(int start, int end, String token, double seconds, boolean down, String rounding) {
            this.start=start; this.end=end; this.token=token; this.seconds=seconds; this.down=down; this.rounding=rounding;
        }
    }
    private static final class Sample {
        double value, at; long generation; int direction;
        Sample(double value, double at, long generation, int direction) {
            this.value=value; this.at=at; this.generation=generation; this.direction=direction;
        }
    }
    private final LinkedHashMap<String, Sample> samples = new LinkedHashMap<>(32, .75f, true);
    public synchronized void clear() { samples.clear(); }
    public synchronized void forget(String prefix) { samples.keySet().removeIf(key -> key.startsWith(prefix + "\n")); }

    public static List<Span> detect(String text, boolean chronometer, boolean countDown,
                                    double clockOffsetSeconds, double textAgeSeconds) {
        return new EmbeddedTimer().observe("",text,chronometer,countDown,clockOffsetSeconds,textAgeSeconds,0,0);
    }
    public synchronized List<Span> observe(String field, String text, boolean chronometer, boolean countDown,
                                          double clockOffsetSeconds, double textAgeSeconds, double nowSeconds, long generation) {
        List<Span> result = new ArrayList<>();
        if (text.length()>1200) return result;
        String template=NUMBERS.matcher(text).replaceAll("#");
        Matcher matcher=CLOCK.matcher(text); int ordinal=0;
        while(matcher.find() && ordinal<4) {
            String token=matcher.group(); double value=0;
            for(String part:token.split(":")) value=value*60+Integer.parseInt(part);
            String key=field+"\n"+template+"\n"+(ordinal++);
            double at=nowSeconds-Math.max(0,textAgeSeconds);
            Sample old=samples.get(key);
            int direction=old==null ? 0:old.direction;
            // A snapshot of the same notification is not a new measurement.
            if(old==null || nowSeconds-old.at>1800 || at<old.at-1) {
                direction=0; samples.put(key,new Sample(value,at,generation,0));
            } else if(old.generation!=generation) {
                double dt=at-old.at, delta=value-old.value;
                if(dt>=1.5) {
                    int observed=delta>0 ? 1:delta<0 ? -1:0;
                    boolean consistent=dt<=60 && observed!=0 && Math.abs(Math.abs(delta)-dt)<=1.1;
                    direction=consistent && (direction==0 || direction==observed) ? observed:0;
                    samples.put(key,new Sample(value,at,generation,direction));
                } else if(value!=old.value && (dt<0 || Math.abs(value-old.value)>2)) {
                    direction=0; samples.put(key,new Sample(value,at,generation,0));
                }
            }
            double metadata=countDown ? clockOffsetSeconds:-clockOffsetSeconds;
            double projected=value+(countDown ? -textAgeSeconds:textAgeSeconds);
            if(chronometer && (direction==0 || (direction<0)==countDown) && Math.min(Math.abs(projected-metadata),Math.abs(value-metadata))<=1.05) {
                result.add(new Span(matcher.start(),matcher.end(),token,Math.max(0,metadata),countDown,"android"));
            } else if(direction!=0) {
                result.add(new Span(matcher.start(),matcher.end(),token,Math.max(0,value+direction*Math.max(0,textAgeSeconds)),direction<0,"sample"));
            }
        }
        while(samples.size()>1024) samples.remove(samples.keySet().iterator().next());
        return result;
    }
}
