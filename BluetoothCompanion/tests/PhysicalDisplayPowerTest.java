package app.droidmirror.bluetooth;

public final class PhysicalDisplayPowerTest {
    private static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        require(PhysicalDisplayPower.restorationMode(1) == 0); // Sleeping stays OFF.
        require(PhysicalDisplayPower.restorationMode(3) == 1); // AOD stays DOZE.
        require(PhysicalDisplayPower.restorationMode(4) == 3); // Suspended AOD stays suspended.
        for (int state : new int[] {2, 5, 6}) require(PhysicalDisplayPower.restorationMode(state) == 2);
        try { PhysicalDisplayPower.restorationMode(0); throw new AssertionError("Unknown policy must not wake"); }
        catch (IllegalStateException expected) {}
        System.out.println("PhysicalDisplayPower: OFF/AOD restoration and unknown-policy safety passed");
    }
}
