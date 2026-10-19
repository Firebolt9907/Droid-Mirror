package app.droidmirror.bluetooth;

public final class AudioVolumeLeaseTest {
    static void check(boolean ok) { if (!ok) throw new AssertionError(); }
    static final class Device implements AudioVolumeLease.Volume {
        int route=2, volume=7, writes;
        boolean muted, fail;
        public int route() { return route; }
        public int lastAudible() { return volume; }
        public boolean muted() { return muted; }
        public void setVolume(int value) throws Exception {
            if (fail) throw new Exception("Audio service unavailable");
            volume=value; muted=value==0; ++writes;
        }
        public void setMuted(boolean value) { muted=value; ++writes; }
    }
    public static void main(String[] args) throws Exception {
        for (boolean muted : new boolean[]{false,true}) {
            Device device=new Device(); device.muted=muted;
            AudioVolumeLease lease=new AudioVolumeLease(device);
            check(device.writes==0 && device.volume==7 && device.muted==muted); // Capture is route-muted, never volume-zeroed.
            device.volume=12; device.muted=!muted;
            lease.restore(); check(device.volume==7 && device.muted==muted);
            int writes=device.writes; lease.restore(); check(writes==device.writes);
        }
        Device zero=new Device(); zero.volume=0; zero.muted=true;
        AudioVolumeLease zeroLease=new AudioVolumeLease(zero);
        zero.volume=8; zero.muted=false; zeroLease.restore(); check(zero.volume==0 && zero.muted);
        Device unchanged=new Device(); AudioVolumeLease failedStart=new AudioVolumeLease(unchanged);
        failedStart.restore(); check(unchanged.writes==0); // A failed/aborted capture doesn't unmute the phone.
        Device routed=new Device(); AudioVolumeLease speaker=new AudioVolumeLease(routed);
        routed.route=0x8000;
        try { speaker.restore(); throw new AssertionError(); } catch(IllegalStateException expected) {}
        check(routed.writes==0);
        routed.route=2; routed.volume=11; speaker.restore(); check(routed.volume==7);
        Device headset=new Device(); AudioVolumeLease oldSpeaker=new AudioVolumeLease(headset);
        headset.route=128; headset.volume=4; oldSpeaker.restore();
        check(headset.writes==0 && headset.volume==4); // Never apply speaker volume to a newly attached headset.
        Device failing=new Device(); AudioVolumeLease retry=new AudioVolumeLease(failing);
        failing.volume=12; failing.fail=true;
        try { retry.restore(); throw new AssertionError(); } catch(Exception expected) {}
        failing.fail=false; retry.restore(); check(failing.volume==7);
        Device active=new Device(); active.route=0x8000;
        try { new AudioVolumeLease(active); throw new AssertionError(); } catch(IllegalStateException expected) {}
        System.out.println("Audio volume: original index/mute, zero volume, abort, idempotence, route-release ordering, new headset and recovery retry passed");
    }
}
