import app.droidmirror.bluetooth.bridge.EmbeddedTimer;
public class EmbeddedTimerTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        check(EmbeddedTimer.detect("Meet at 12:30",false,false,0,0).isEmpty());
        check(EmbeddedTimer.detect("Score 2:06",false,false,0,0).isEmpty());
        check(EmbeddedTimer.detect("Zone shrinks in 00:16",true,false,-1511,0).isEmpty());
        check(EmbeddedTimer.detect("Runner · 02:06",true,true,118,8).size()==1);
        EmbeddedTimer d=new EmbeddedTimer();
        check(d.observe("a\nbody","1 runner left · Reveal in 00:16\nZone shrinks in 00:16",true,false,-1511,0,100,1).isEmpty());
        var spans=d.observe("a\nbody","2 runners left · Reveal in 00:11\nZone shrinks in 00:11",true,false,-1516,0,105,2);
        check(spans.isEmpty()); // Literal structure changed: do not reuse a different field's history.
        spans=d.observe("a\nbody","2 runners left · Reveal in 00:06\nZone shrinks in 00:06",true,false,-1521,0,110,3);
        check(spans.size()==2 && spans.stream().allMatch(s -> s.down && s.seconds==6));
        check(d.observe("a\nbody","2 runners left · Reveal in 00:06\nZone shrinks in 00:06",true,false,-1523,2,112,3).size()==2); // snapshot
        check(d.observe("a\nbody","2 runners left · Reveal in 00:06\nZone shrinks in 00:06",true,false,-1526,0,115,4).isEmpty()); // stopped
        check(d.observe("b\nbody","任意の言葉 🏃 00:16",false,false,0,0,100,1).isEmpty());
        spans=d.observe("b\nbody","任意の言葉 🏃 00:11",false,false,0,2,107,2);
        check(spans.size()==1 && spans.get(0).seconds==9 && spans.get(0).down);
        check(d.observe("c\nbody","Anything 03:00",false,false,0,0,100,1).isEmpty());
        spans=d.observe("c\nbody","Anything 03:05",false,false,0,0,105,2);
        check(spans.size()==1 && !spans.get(0).down);
        check(d.observe("d\nbody","Score 2:06",false,false,0,0,100,1).isEmpty());
        check(d.observe("d\nbody","Score 2:07",false,false,0,0,105,2).isEmpty());
        check(d.observe("e\nbody","Time 12:30",false,false,0,0,100,1).isEmpty());
        check(d.observe("e\nbody","Time 12:31",false,false,0,0,160,2).isEmpty());
        d.forget("b");
        check(d.observe("b\nbody","任意の言葉 🏃 00:06",false,false,0,0,110,3).isEmpty());
        d.clear();
        check(d.observe("b\nbody","任意の言葉 🏃 00:01",false,false,0,0,115,4).isEmpty());
        System.out.println("Embedded timer temporal-inference and metadata tests passed");
    }
}
