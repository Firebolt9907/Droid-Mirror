import app.droidmirror.bluetooth.bridge.ClipboardTransferRace;
import org.json.JSONObject;
import java.util.*;
import java.security.MessageDigest;
import kotlin.Unit;

public final class ClipboardTransferRaceTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static JSONObject event(String type, String id) { return new JSONObject().put("type", type).put("id", id); }
    public static void main(String[] args) throws Exception {
        byte[] bytes = new byte[100000]; for (int i=0;i<bytes.length;i++) bytes[i]=(byte)(i%251);
        StringBuilder hex = new StringBuilder(); for (byte b: MessageDigest.getInstance("SHA-256").digest(bytes)) hex.append(String.format("%02x",b&255));
        for (int scenario=0;scenario<3;scenario++) {
            int winning=scenario==0?0:1;
            String id=UUID.randomUUID().toString().toUpperCase(Locale.ROOT);
            List<ArrayDeque<JSONObject>> queues=List.of(new ArrayDeque<>(),new ArrayDeque<>());
            ClipboardTransferRace[] sender=new ClipboardTransferRace[1],receiver=new ClipboardTransferRace[1];
            int[] sent={0},applies={0}; java.io.ByteArrayOutputStream output=new java.io.ByteArrayOutputStream(); List<Integer> wins=new ArrayList<>();
            boolean[] broken={false};
            sender[0]=new ClipboardTransferRace((lane,value)->{if(lane==1&&broken[0])return false;queues.get(lane).add(value);return true;}, value->{
                if(value.optString("type").equals("clipboardFileAck")) for(int i=0;i<32&&sent[0]<bytes.length;i++) {
                    int end=Math.min(bytes.length,sent[0]+3072);
                    JSONObject chunk=event("clipboardFileChunk",id).put("offset",sent[0]).put("data",Base64.getEncoder().encodeToString(Arrays.copyOfRange(bytes,sent[0],end)));
                    sent[0]=end;check(sender[0].send(chunk));
                }
                return Unit.INSTANCE;
            },lane->Unit.INSTANCE);
            receiver[0]=new ClipboardTransferRace((lane,value)->{sender[0].receive(value,lane);return true;}, value->{
                if(value.optString("type").equals("clipboardFileBegin")) {
                    check(value.optString("destination").equals("downloads"));
                    receiver[0].send(event("clipboardFileAck",id).put("offset",0).put("window",32));
                }
                if(value.optString("type").equals("clipboardFileChunk")) {
                    check(value.getInt("offset")==output.size()); output.writeBytes(Base64.getDecoder().decode(value.getString("data")));
                    if(output.size()==bytes.length){applies[0]++;receiver[0].send(event("clipboardFileAck",id).put("offset",bytes.length));}
                }
                return Unit.INSTANCE;
            },lane->{wins.add(lane);return Unit.INSTANCE;});
            check(sender[0].send(event("clipboardFileBegin",id).put("size",bytes.length).put("sha256",hex.toString()).put("name","test.png").put("window",32).put("destination","downloads")));
            for(int i=0;i<3&&!queues.get(1-winning).isEmpty();i++)receiver[0].receive(queues.get(1-winning).remove(),1-winning);
            check(applies[0]==0);
            if(scenario==2) {
                for(int i=0;i<3;i++)receiver[0].receive(queues.get(1).remove(),1);
                broken[0]=true;
                for(int i=0;i<30;i++)receiver[0].receive(queues.get(0).remove(),0);
                check(applies[0]==0);
                queues.get(1).clear();sender[0].restartLane(1);receiver[0].restartLane(1);broken[0]=false;
                sender[0].catchUp(1);
            }
            while(!queues.get(winning).isEmpty())receiver[0].receive(queues.get(winning).remove(),winning);
            check(Arrays.equals(bytes,output.toByteArray())&&applies[0]==1&&wins.equals(List.of(winning)));
            while(!queues.get(1-winning).isEmpty())receiver[0].receive(queues.get(1-winning).remove(),1-winning);
            check(applies[0]==1);
        }
        System.out.println("PASS: Android production race, either winner, independent copies, failed IP replay with continuing BLE and late duplicate suppression");
    }
}
