import app.droidmirror.bluetooth.DisplayLease;
import com.genymobile.scrcpy.control.IdleUhidKeyboard;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import java.io.FileDescriptor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

public final class IdleUhidKeyboardTest {

    static void require(boolean ok) {
        if (!ok) {
            throw new AssertionError();
        }
    }

    static final class MockUhid implements Os.MockHandler {
        final List<byte[]> writes = new ArrayList<>();
        boolean opened;
        boolean closed;
        boolean failOpen;
        boolean failWrite;
        FileDescriptor testFd = new FileDescriptor();

        @Override
        public FileDescriptor open(String path, int flags, int mode) throws Exception {
            require("/dev/uhid".equals(path));
            require((flags & OsConstants.O_RDWR) != 0);
            require((flags & OsConstants.O_CLOEXEC) != 0);
            if (failOpen) {
                throw new ErrnoException("open", 13); // EACCES
            }
            opened = true;
            closed = false;
            return testFd;
        }

        @Override
        public int write(FileDescriptor fd, byte[] bytes, int byteOffset, int byteCount) throws Exception {
            if (failWrite) {
                throw new ErrnoException("write", 5); // EIO
            }
            byte[] copy = new byte[byteCount];
            System.arraycopy(bytes, byteOffset, copy, 0, byteCount);
            writes.add(copy);
            return byteCount;
        }

        @Override
        public void close(FileDescriptor fd) throws Exception {
            closed = true;
        }
    }

    public static void main(String[] args) {
        // Test 1: Successful creation and UHID_CREATE2 packet format
        MockUhid mock = new MockUhid();
        Os.mockHandler = mock;

        IdleUhidKeyboard keyboard = new IdleUhidKeyboard();
        require(!keyboard.isActive());

        require(keyboard.create());
        require(keyboard.isActive());
        require(mock.opened);
        require(mock.writes.size() == 1);

        byte[] createReq = mock.writes.get(0);
        require(createReq.length == 280 + 63); // 280-byte header + 63-byte report descriptor

        ByteBuffer buf = ByteBuffer.wrap(createReq).order(ByteOrder.nativeOrder());
        int type = buf.getInt();
        require(type == 11); // UHID_CREATE2

        byte[] nameBytes = new byte[128];
        buf.get(nameBytes);
        String name = new String(nameBytes).trim();
        // Gboard remembers a per-device "show software keyboard" override for
        // the former Android Mirror Virtual Keyboard name independently of the
        // system setting. Keep the new product identity stable across sessions.
        require("Droidmirror Virtual Keyboard".equals(name));

        // Match scrcpy's virtual bus. A USB keyboard with arrow
        // keys can be classified as a non-alphabetic external DPAD until it
        // produces a letter; this idle device never produces keystrokes.
        byte[] physBytes = new byte[64];
        buf.get(physBytes);
        require("droidmirror:keyboard".equals(new String(physBytes).trim()));
        for (int i = 196; i < 260; ++i) {
            require(createReq[i] == 0); // no unique-id/display association
        }

        buf.position(4 + 128 + 64 + 64); // skip name, phys, uniq -> offset 260
        short rdSize = buf.getShort();
        require(rdSize == 63);

        short bus = buf.getShort();
        require(bus == 6); // BUS_VIRTUAL, as used by scrcpy --keyboard=uhid

        int vendor = buf.getInt();
        require(vendor == 0); // no vendor-specific key layout or classification

        int product = buf.getInt();
        require(product == 0);

        // Calling create() again while active must be a no-op
        require(keyboard.create());
        require(mock.writes.size() == 1);

        // Test 2: Idempotent destruction
        keyboard.destroy();
        require(!keyboard.isActive());
        require(mock.closed);
        require(mock.writes.size() == 2);

        byte[] destroyReq = mock.writes.get(1);
        require(destroyReq.length == 4);
        ByteBuffer destroyBuf = ByteBuffer.wrap(destroyReq).order(ByteOrder.nativeOrder());
        require(destroyBuf.getInt() == 1); // UHID_DESTROY

        // Repeated destroy calls must be safe and idempotent
        keyboard.destroy();
        require(!keyboard.isActive());
        require(mock.writes.size() == 2);

        // Test 3: Failure rollback on open error
        mock = new MockUhid();
        mock.failOpen = true;
        Os.mockHandler = mock;

        keyboard = new IdleUhidKeyboard();
        require(!keyboard.create());
        require(!keyboard.isActive());
        require(!mock.opened);
        require(mock.writes.isEmpty());

        // Test 4: Failure rollback on write error
        mock = new MockUhid();
        mock.failWrite = true;
        Os.mockHandler = mock;

        keyboard = new IdleUhidKeyboard();
        require(!keyboard.create());
        require(!keyboard.isActive());
        require(mock.opened);
        require(mock.closed); // fd must be closed on write failure

        // Test 5: Integration with DisplayLease recovery
        mock = new MockUhid();
        Os.mockHandler = mock;

        keyboard = new IdleUhidKeyboard();
        require(keyboard.create());
        require(keyboard.isActive());

        AtomicLong clock = new AtomicLong(1);
        DisplayLease.Power power = on -> {};
        DisplayLease lease = new DisplayLease(power, clock::get, keyboard::destroy);

        Object token = new Object();
        require(lease.acquire(token));
        require(keyboard.isActive()); // Still active during mirroring session

        // When display is recovered / session ends, keyboard must be destroyed
        require(lease.recover());
        require(!keyboard.isActive());
        require(mock.closed);

        System.out.println("IdleUhidKeyboard: creation, UHID_CREATE2 payload, destroy, idempotency, failure rollback, and DisplayLease integration passed");
    }
}
