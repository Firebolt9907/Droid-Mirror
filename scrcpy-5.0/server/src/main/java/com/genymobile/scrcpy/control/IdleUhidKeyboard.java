package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.util.Ln;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import java.io.FileDescriptor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * Advertises a virtual HID keyboard to Android via /dev/uhid without injecting keystrokes.
 * <p>
 * This prompts Android (and Gboard) to recognize a physical hardware keyboard and suppress the
 * on-screen software keyboard, while actual typing continues through scrcpy's SDK key injection.
 */
public final class IdleUhidKeyboard implements AutoCloseable {

    private static final int UHID_DESTROY = 1;
    private static final int UHID_CREATE2 = 11;
    // Match UhidManager/scrcpy --keyboard=uhid. With BUS_USB, Android's keyboard
    // classifier treats the arrow keys in this descriptor as an external DPAD
    // and may defer alphabetic classification until a letter is pressed. This
    // device is intentionally idle, so that would leave the software IME visible.
    private static final short BUS_VIRTUAL = 0x06;

    private static final int VENDOR_ID = 0;
    private static final int PRODUCT_ID = 0;
    private static final String DEVICE_NAME = "Droidmirror Virtual Keyboard";
    // Keep this identity separate from scrcpy and other UHID devices with zero
    // vendor/product IDs. Android may merge devices with an empty physical port,
    // retaining the old device name and its IME-specific visibility preference.
    private static final String INPUT_PORT = "droidmirror:keyboard";

    // Standard 63-byte HID keyboard report descriptor from scrcpy
    private static final byte[] KEYBOARD_REPORT_DESC = {
        0x05, 0x01,                    // Usage Page (Generic Desktop)
        0x09, 0x06,                    // Usage (Keyboard)
        (byte) 0xA1, 0x01,             // Collection (Application)
        0x05, 0x07,                    // Usage Page (Key Codes)
        0x19, (byte) 0xE0,             // Usage Minimum (224)
        0x29, (byte) 0xE7,             // Usage Maximum (231)
        0x15, 0x00,                    // Logical Minimum (0)
        0x25, 0x01,                    // Logical Maximum (1)
        0x75, 0x01,                    // Report Size (1)
        (byte) 0x95, 0x08,             // Report Count (8)
        (byte) 0x81, 0x02,             // Input (Data, Variable, Absolute): Modifier byte
        0x75, 0x08,                    // Report Size (8)
        (byte) 0x95, 0x01,             // Report Count (1)
        (byte) 0x81, 0x01,             // Input (Constant): Reserved byte
        0x05, 0x08,                    // Usage Page (LEDs)
        0x19, 0x01,                    // Usage Minimum (1)
        0x29, 0x05,                    // Usage Maximum (5)
        0x75, 0x01,                    // Report Size (1)
        (byte) 0x95, 0x05,             // Report Count (5)
        (byte) 0x91, 0x02,             // Output (Data, Variable, Absolute): LED report
        0x75, 0x03,                    // Report Size (3)
        (byte) 0x95, 0x01,             // Report Count (1)
        (byte) 0x91, 0x01,             // Output (Constant): LED report padding
        0x05, 0x07,                    // Usage Page (Key Codes)
        0x19, 0x00,                    // Usage Minimum (0)
        0x29, 0x65,                    // Usage Maximum (101)
        0x15, 0x00,                    // Logical Minimum (0)
        0x25, 0x65,                    // Logical Maximum (101)
        0x75, 0x08,                    // Report Size (8)
        (byte) 0x95, 0x06,             // Report Count (6)
        (byte) 0x81, 0x00,             // Input (Data, Array): Keys
        (byte) 0xC0                    // End Collection
    };

    private FileDescriptor fd;
    private boolean creationFailed;

    public synchronized boolean create() {
        if (isActive()) {
            return true;
        }
        if (creationFailed) {
            // Avoid tight retry loops if creation has already failed for this session instance.
            return false;
        }
        FileDescriptor openFd = null;
        try {
            openFd = Os.open("/dev/uhid", OsConstants.O_RDWR | OsConstants.O_CLOEXEC, 0);
            byte[] req = buildUhidCreate2Req(VENDOR_ID, PRODUCT_ID, DEVICE_NAME, KEYBOARD_REPORT_DESC);
            Os.write(openFd, req, 0, req.length);
            this.fd = openFd;
            Ln.i("Idle UHID keyboard registered: " + DEVICE_NAME);
            return true;
        } catch (Throwable t) {
            creationFailed = true;
            if (openFd != null) {
                closeFd(openFd);
            }
            Ln.w("Could not register idle UHID keyboard (SDK injection remains active): " + t.getMessage());
            return false;
        }
    }

    public synchronized void destroy() {
        if (fd == null) {
            return;
        }
        FileDescriptor closeTarget = fd;
        fd = null; // Mark inactive before destruction to guarantee idempotency.
        try {
            ByteBuffer buf = ByteBuffer.allocate(4).order(ByteOrder.nativeOrder());
            buf.putInt(UHID_DESTROY);
            Os.write(closeTarget, buf.array(), 0, 4);
        } catch (Throwable t) {
            Ln.d("UHID_DESTROY write ignored: " + t.getMessage());
        } finally {
            closeFd(closeTarget);
            Ln.i("Idle UHID keyboard destroyed");
        }
    }

    public synchronized boolean isActive() {
        return fd != null;
    }

    @Override
    public void close() {
        destroy();
    }

    private static void closeFd(FileDescriptor fd) {
        if (fd != null) {
            try {
                Os.close(fd);
            } catch (ErrnoException e) {
                Ln.w("Failed to close /dev/uhid: " + e.getMessage());
            }
        }
    }

    private static byte[] buildUhidCreate2Req(int vendorId, int productId, String name, byte[] reportDesc) {
        ByteBuffer buf = ByteBuffer.allocate(280 + reportDesc.length).order(ByteOrder.nativeOrder());
        buf.putInt(UHID_CREATE2);

        byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
        int nameLen = Math.min(nameBytes.length, 127);
        buf.put(nameBytes, 0, nameLen);

        buf.position(4 + 128);
        buf.put(INPUT_PORT.getBytes(StandardCharsets.US_ASCII));

        // rd_size: offset 4 + 256 = 260
        buf.position(4 + 256);
        buf.putShort((short) reportDesc.length);
        buf.putShort(BUS_VIRTUAL);
        buf.putInt(vendorId);
        buf.putInt(productId);
        buf.putInt(0); // version
        buf.putInt(0); // country
        buf.put(reportDesc);
        return buf.array();
    }
}
