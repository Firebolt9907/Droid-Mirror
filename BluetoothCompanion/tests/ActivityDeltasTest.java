import app.droidmirror.bluetooth.bridge.ActivityDeltas;
import org.json.*;
public class ActivityDeltasTest {
    static void check(boolean ok) { if (!ok) throw new AssertionError(); }
    static JSONObject event(String version, double offset, String body, double seconds) {
        JSONObject span = new JSONObject().put("hash",body.hashCode()).put("start",10).put("end",15)
            .put("token",body.substring(10,15)).put("seconds",seconds).put("down",true).put("hours",false).put("width",2);
        return new JSONObject().put("type","notification").put("id","runner").put("version",version)
            .put("activity",true).put("title","Runner").put("body",body).put("chronometer",true).put("countDown",true)
            .put("clockOffsetMs",offset).put("embeddedTimers",new JSONArray().put(span))
            .put("appIcon","A".repeat(1024)).put("activityIcon","B".repeat(768))
            .put("progressTrackerIcon","C".repeat(384)).put("actions",new JSONArray().put(new JSONObject().put("id","0").put("title","Pause")));
    }
    public static void main(String[] args) throws Exception {
        ActivityDeltas sender=new ActivityDeltas();
        JSONObject first=event("v1",126000,"Starts in 02:06",126);
        check(sender.encode(first,1000).getString("type").equals("notification"));
        sender.setEnabled(true);
        check(sender.encode(first,1000).getString("type").equals("notification"));
        JSONObject next=event("v2",125000,"Starts in 02:05",125);
        JSONObject patch=sender.encode(next,2000);
        check(patch.getString("type").equals("activityPatch"));
        JSONObject fields=patch.getJSONObject("set");
        check(!fields.has("appIcon") && !fields.has("body") && !fields.has("embeddedTimers") && !fields.has("clockOffsetMs"));
        check(patch.getString("base").equals("v1"));
        int fullBytes=next.toString().getBytes("UTF-8").length, patchBytes=patch.toString().getBytes("UTF-8").length;
        check(patchBytes*10<fullBytes);
        JSONObject later=event("v3",65000,"Starts in 01:05",65);
        JSONObject laterPatch=sender.encode(later,62000);
        check(!laterPatch.getJSONObject("set").has("clockOffsetMs") && !laterPatch.getJSONObject("set").has("embeddedTimers"));
        JSONObject correction=event("v4",60000,"Starts in 01:00",60);
        JSONObject fix=sender.encode(correction,63000);
        check(fix.getJSONObject("set").has("clockOffsetMs") && fix.getJSONObject("set").has("embeddedTimers"));
        JSONObject changed=event("v5",59000,"Return in 00:59",59);
        JSONObject change=sender.encode(changed,64000);
        check(change.getJSONObject("set").getString("body").equals("Return in 00:59"));
        check(change.getJSONObject("set").has("embeddedTimers"));
        JSONObject paused=event("v6",58000,"Paused at 00:58",58);
        paused.put("chronometer",false).remove("embeddedTimers");
        JSONObject pause=sender.encode(paused,65000);
        check(!pause.getJSONObject("set").getBoolean("chronometer"));
        check(pause.getJSONArray("unset").toString().contains("embeddedTimers"));
        JSONObject snapshot=event("v7",57000,"Starts in 00:57",57).put("snapshot",true);
        check(sender.encode(snapshot,66000).getString("type").equals("notification"));
        sender.encode(new JSONObject().put("type","removed").put("id","runner"),67000);
        check(sender.encode(first,68000).getString("type").equals("notification"));
        if(args.length>0) java.nio.file.Files.writeString(java.nio.file.Path.of(args[0]),new JSONArray().put(first).put(patch).put(laterPatch).put(fix).toString());
        System.out.println("PASS: activity deltas, predictive timers, corrections, pause, snapshots and removal; representative update "+fullBytes+" -> "+patchBytes+" JSON bytes");
    }
}
