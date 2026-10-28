import com.genymobile.scrcpy.control.WheelScroll;
import java.util.*;

public final class WheelScrollTest {
    static void require(boolean value) { if(!value) throw new AssertionError(); }
    static final class Trace implements WheelScroll.Sink {
        double distanceX,distanceY; int x,y,downs,ups,moves,cancels; boolean down,negativeOnly;
        public void touch(int action,int nx,int ny) {
            require(nx>=1 && nx<=462 && ny>=1 && ny<=1054);
            if(action==0) { require(!down); down=true; ++downs; }
            else { require(down); if(action==2) { if(negativeOnly) require(ny<=y); distanceX+=nx-x; distanceY+=ny-y; ++moves; } else { require(action==1 || action==3);down=false;++ups;if(action==3)++cancels; } }
            x=nx;y=ny;
        }
    }
    static void settle(WheelScroll scroll,long start) { for(long t=start;t<start+3000;t+=16) scroll.tick(t); require(!scroll.isActive()); }
    public static void main(String[] args) {
        Trace trace=new Trace(); WheelScroll scroll=new WheelScroll(464,1056,232,528,trace);
        scroll.add(0,-120,0); require(trace.downs==1 && trace.moves==0); scroll.tick(16);
        require(trace.distanceY<0 && trace.distanceY>-120); settle(scroll,32);
        require(trace.downs==1 && trace.ups==1 && trace.moves>3 && Math.abs(trace.distanceY+120)<=1);
        trace=new Trace(); scroll=new WheelScroll(464,1056,232,528,trace);
        for(int i=0;i<120;++i) { if(i%2==0) scroll.add(1,-4,i*16); scroll.tick(i*16); }
        settle(scroll,1920); require(Math.abs(trace.distanceX-60)<=1 && Math.abs(trace.distanceY+240)<=1);
        require(trace.downs==1 && trace.ups==1 && trace.moves>60); // Playback is independent of command cadence.
        trace=new Trace(); scroll=new WheelScroll(464,1056,232,528,trace);
        scroll.add(0,5000,0); settle(scroll,16);
        require(trace.downs>1 && trace.ups==trace.downs && Math.abs(trace.distanceY-5000)<=trace.downs);
        trace=new Trace(); scroll=new WheelScroll(464,1056,232,528,trace);
        scroll.add(20,-100,0);scroll.tick(16);scroll.add(-20,100,17);settle(scroll,32);
        require(Math.abs(trace.distanceX)<=1 && Math.abs(trace.distanceY)<=1);
        trace=new Trace();scroll=new WheelScroll(464,1056,232,528,trace);
        scroll.add(0,-100,0);scroll.tick(16);scroll.cancel();int moves=trace.moves;scroll.tick(1000);
        require(trace.ups==1 && trace.cancels==1 && trace.moves==moves && !trace.down);
        scroll.add(0,0,1100); require(!scroll.isActive());
        trace=new Trace(); scroll=new WheelScroll(464,1056,232,528,trace);
        scroll.add(0,1000,0); scroll.tick(16); scroll.cancel();
        double beforeReverse=trace.distanceY; trace.negativeOnly=true;
        scroll.add(0,-100,17); settle(scroll,32);
        require(Math.abs(trace.distanceY-beforeReverse+100)<=1); // No old momentum after reset.
        for (int[] anchor : new int[][] {{1,1},{462,1054},{51,817}}) {
            trace=new Trace(); scroll=new WheelScroll(464,1056,anchor[0],anchor[1],trace);
            scroll.add(anchor[0]==1 ? -40 : 40,anchor[1]==1 ? -40 : 40,0);
            require(trace.x==anchor[0] && trace.y==anchor[1]);
            settle(scroll,16);
            require(trace.ups==trace.downs && Math.abs(Math.abs(trace.distanceX)-40)<=1
                    && Math.abs(Math.abs(trace.distanceY)-40)<=1);
        }
        // A pager commits on UP but rolls back on CANCEL. Normal horizontal
        // swipes must complete in both directions, including across re-anchors.
        for(int distance : new int[] {-180,180,-400,400,-1000,1000}) {
            trace=new Trace(); scroll=new WheelScroll(464,1056,232,528,trace);
            scroll.add(distance,0,0); settle(scroll,16);
            require(trace.cancels==0 && trace.ups==trace.downs);
            require(Math.abs(trace.distanceX-distance)<=trace.downs);
        }
        System.out.println("Wheel scroll: local frame pacing, committed horizontal swipes, summed distance, reversal, rebasing, idle release and cancellation passed");
    }
}
