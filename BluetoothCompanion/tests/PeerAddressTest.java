package app.droidmirror.bluetooth;
import java.net.*;
import java.nio.ByteBuffer;
import java.util.*;
public final class PeerAddressTest {
    public static void main(String[] args) throws Exception {
        InetAddress tailscale=InetAddress.getByName("100.108.251.24");
        InetAddress v6=InetAddress.getByName("fd7a:115c:a1e0::dc01:fb19");
        List<byte[]> records=PeerAddress.candidates("10.1.2.3:45678\n[2001:db8::1]:45679\ninvalid", List.of(tailscale,v6));
        if (records.size()!=4) throw new AssertionError("VPN candidates were omitted");
        byte[] ip4=records.get(2), ip6=records.get(3);
        if (ip4.length!=32 || ip4[8]!=4 || ip6[8]!=16) throw new AssertionError("Address envelope");
        if (!Arrays.equals(Arrays.copyOfRange(ip4,9,13), tailscale.getAddress())) throw new AssertionError("IPv4");
        if (!Arrays.equals(Arrays.copyOfRange(ip6,9,25), v6.getAddress())) throw new AssertionError("IPv6");
        if (Short.toUnsignedInt(ByteBuffer.wrap(ip4,25,2).getShort())!=45678
            || Short.toUnsignedInt(ByteBuffer.wrap(ip6,25,2).getShort())!=45679) throw new AssertionError("Wrong UDP port family");
        if (PeerAddress.encode(InetAddress.getByName("127.0.0.1"),1)!=null
            || PeerAddress.encode(InetAddress.getByName("ff02::1"),1)!=null
            || PeerAddress.encode(tailscale,0)!=null) throw new AssertionError("Unsafe candidates");
        if (!PeerAddress.candidates("",List.of(tailscale)).isEmpty()) throw new AssertionError("Invented UDP port");
        List<byte[]> wildcard=PeerAddress.candidates("0.0.0.0:45678\n[::]:45679", List.of(tailscale,v6));
        if (wildcard.size()!=2 || wildcard.get(0)[9]!=100) throw new AssertionError("VPN omitted with wildcard bind ports");
        if (PeerAddress.reset().length!=32 || PeerAddress.reset()[8]!=0) throw new AssertionError("Reset");
        System.out.println("Peer addresses: Tailscale IPv4/IPv6, actual bound ports, binary encoding and unsafe-address rejection passed");
    }
}
