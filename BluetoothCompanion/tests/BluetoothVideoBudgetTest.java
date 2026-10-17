import app.droidmirror.bluetooth.BluetoothVideoBudget;

public final class BluetoothVideoBudgetTest {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    static long feed(BluetoothVideoBudget budget, long count, int bytes, int interval, long start, int samples) {
        for (int i = 0; i < samples; ++i) {
            count += bytes;
            int capacity = budget.acknowledge(count, start + (long)i * interval);
            require(capacity >= BluetoothVideoBudget.MIN_BYTES && capacity <= BluetoothVideoBudget.MAX_BYTES);
        }
        return count;
    }
    public static void main(String[] args) {
        BluetoothVideoBudget budget = new BluetoothVideoBudget();
        long count = feed(budget, 0, 1024, 40, 0, 100);
        require(budget.capacityBytes() == BluetoothVideoBudget.MIN_BYTES);
        require(budget.deliveredBytesPerSecond() == 25600);
        count = feed(budget, count, 8192, 40, 4000, 250);
        // A fast link needs room for multiple ACK intervals, not a fixed 8 KiB.
        require(budget.capacityBytes() > 40 * 1024);
        require(budget.deliveredBytesPerSecond() > 200000);
        count = feed(budget, count, 512, 40, 14000, 300);
        require(budget.capacityBytes() == BluetoothVideoBudget.MIN_BYTES); // Slowdown contracts backlog.
        count = feed(budget, count, 65536, 40, 26000, 200);
        require(budget.capacityBytes() == BluetoothVideoBudget.MAX_BYTES);
        budget.acknowledge(count, 34500); // No progress for >500 ms: idle is not a low-rate sample.
        require(budget.capacityBytes() == BluetoothVideoBudget.MIN_BYTES);
        require(budget.deliveredBytesPerSecond() == 0);
        budget.reset(count); // A Wi-Fi estimate must not leak into Bluetooth fallback.
        require(budget.capacityBytes() == BluetoothVideoBudget.MIN_BYTES);
        feed(budget, count, 32768, 240, 35000, 100); // Delayed/coalesced BLE ACKs.
        require(budget.capacityBytes() > 48 * 1024);
        System.out.println("Bluetooth budget: slow/fast delivery, contraction, hard cap, idle, reset and delayed ACKs passed");
    }
}
