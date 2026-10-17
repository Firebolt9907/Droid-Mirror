package app.droidmirror.bluetooth;

import java.net.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Fixed-size hints carried only inside authenticated BLE setup envelopes. */
final class PeerAddress {
    static final byte[] MAGIC = "DMIP0001".getBytes(StandardCharsets.US_ASCII);
    static byte[] reset() { return ByteBuffer.allocate(32).put(MAGIC).array(); }
    static byte[] encode(InetAddress address, int port) {
        if (port < 1 || port > 65535 || address.isAnyLocalAddress() || address.isLoopbackAddress()
                || address.isMulticastAddress() || address.isLinkLocalAddress()) return null;
        byte[] ip = address.getAddress();
        if (ip.length != 4 && ip.length != 16) return null;
        ByteBuffer bytes = ByteBuffer.allocate(32).put(MAGIC).put((byte)ip.length);
        bytes.put(ip); bytes.position(25); bytes.putShort((short)port);
        return bytes.array();
    }
    static List<byte[]> candidates(String nativeAddresses, Collection<InetAddress> interfaces) {
        int v4 = 0, v6 = 0;
        Map<String, byte[]> result = new LinkedHashMap<>();
        for (String line : nativeAddresses.split("\n")) {
            try {
                int colon = line.lastIndexOf(':');
                if (colon < 1 || colon == line.length()-1) continue;
                String host = line.substring(0, colon).replace("[", "").replace("]", "");
                if (!(host.contains(":") ? host.matches("[0-9a-fA-F:]+") : host.matches("[0-9.]+"))) continue;
                InetAddress address = InetAddress.getByName(host);
                int port = Integer.parseInt(line.substring(colon + 1));
                if (port < 1 || port > 65535) continue;
                // Wildcard bind addresses supply real per-family UDP ports even
                // if native interface discovery omitted the VPN interface.
                if (address instanceof Inet4Address) v4 = port; else v6 = port;
                byte[] record = encode(address, port);
                if (record == null) continue;
                result.put(address.getHostAddress() + ":" + port, record);
            } catch (IllegalArgumentException | UnknownHostException ignored) { }
        }
        // Android interface enumeration can see VPN addresses that Iroh's native
        // address enumeration omits. The wildcard UDP listener accepts these too.
        for (InetAddress address : interfaces) {
            int port = address instanceof Inet4Address ? v4 : v6;
            byte[] record = encode(address, port);
            if (record != null) result.put(address.getHostAddress() + ":" + port, record);
        }
        List<byte[]> records = new ArrayList<>(result.values());
        return records.subList(0, Math.min(records.size(), 32));
    }
}
