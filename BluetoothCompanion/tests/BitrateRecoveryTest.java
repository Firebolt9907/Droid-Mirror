import com.genymobile.scrcpy.video.BitrateRecovery;
import app.droidmirror.bluetooth.HevcCapturePolicy;

public final class BitrateRecoveryTest {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        BitrateRecovery rate = new BitrateRecovery(64000);
        require(rate.healthy(0) == 64000);
        require(rate.stalled() == 32000);
        require(rate.healthy(1) == 32000);
        require(rate.healthy(20000000) == 32000); // Idle time is not measured healthy throughput.
        for (long now = 20100000; now <= 30000000; now += 100000) require(rate.healthy(now) == (now == 30000000 ? 40000 : 32000));
        require(rate.stalled() == 32000); // Congestion resets recovery.
        for (long now = 40000000; now <= 100000000; now += 100000) {
            int bitrate = rate.healthy(now);
            require(bitrate >= 32000 && bitrate <= 64000);
        }
        require(rate.healthy(100100000) == 64000);
        require(new BitrateRecovery(16000).stalled() == 16000);
        BitrateRecovery early = new BitrateRecovery(256000);
        require(early.backlogged(0) == 192000);
        require(early.backlogged(999999) == 192000); // At most one change per second.
        require(early.backlogged(1000000) == 144000);
        require(early.healthy(1100000) == 144000);
        require(early.backlogged(1500000) == 144000); // A new backlog resets healthy recovery.
        for (long now=2000000;now<=12000000;now+=100000) early.healthy(now);
        require(early.healthy(12100000) == 180000);
        for (long now = 13000000; now < 30000000; now += 1000000) {
            require(early.backlogged(now) >= 128000);
        }
        require(early.stalled() == 128000);
        require(early.stalled() == 128000); // Repeated congestion must not collapse quality.
        BitrateRecovery probing = new BitrateRecovery(256000, 1500000, 2000000);
        require(probing.healthy(0) == 256000);
        require(probing.healthy(20000000) == 256000); // Idle time cannot trigger a probe.
        for (long now = 20100000; now <= 40000000; now += 100000) probing.healthy(now);
        require(probing.healthy(40100000) == 1500000); // Healthy link exceeds old 256 kbps ceiling.
        require(probing.backlogged(41000000) == 1125000);
        require(probing.backlogged(41500000) == 1125000); // One reduction per second.
        for (long now = 42000000; now <= 60000000; now += 1000000) probing.backlogged(now);
        require(probing.stalled() == 128000); // Ceiling must not raise the congestion floor.
        for (long now = 61000000; now <= 65000000; now += 100000) probing.healthy(now);
        require(probing.healthy(65100000) > 128000); // Resume probing after congestion clears.
        require(HevcCapturePolicy.BLUETOOTH_BIT_RATE == 128000);
        require(HevcCapturePolicy.BLUETOOTH_MAX_BIT_RATE == HevcCapturePolicy.BLUETOOTH_BIT_RATE);
        BitrateRecovery bluetooth = new BitrateRecovery(HevcCapturePolicy.BLUETOOTH_BIT_RATE);
        for (long now = 0; now <= 30000000; now += 62500) {
            require(bluetooth.healthy(now) == 128000);
        }
        require(bluetooth.healthy(30062500) == 128000);
        for (long now = 31000000; now <= 40000000; now += 1000000) bluetooth.backlogged(now);
        require(bluetooth.stalled() == 64000); // Fit links below the old 128 kbps floor.
        // Recovery needs ten continuous healthy seconds and never exceeds startup quality.
        for (long now = 41000000; now < 51000000; now += 100000) require(bluetooth.healthy(now) == 64000);
        require(bluetooth.healthy(51000000) == 80000);
        for (long now = 51100000; now <= 100000000; now += 100000) require(bluetooth.healthy(now) <= 128000);
        require(bluetooth.healthy(100100000) == 128000);
        // A nominal 12 Mbps profile must adapt below 6 Mbps when a VPN or
        // congested Wi-Fi path cannot sustain it, then recover gradually.
        BitrateRecovery wifi = new BitrateRecovery(12000000, 12000000, 10000000,
                HevcCapturePolicy.MIN_ADAPTIVE_BIT_RATE);
        for (long now = 0; now < 30000000; now += 1000000) wifi.backlogged(now);
        require(wifi.stalled() == HevcCapturePolicy.MIN_ADAPTIVE_BIT_RATE);
        for (long now = 30000000; now < 40000000; now += 100000) require(wifi.healthy(now) == 64000);
        require(wifi.healthy(40000000) == 80000);
        System.out.println("Bitrate recovery: sustained progress, idle gaps, congestion reset, target ceiling and bandwidth probing passed");
    }
}
