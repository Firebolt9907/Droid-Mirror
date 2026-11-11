import org.json.*;

/** ESPN-like cards must retain both teams and trailing game status under the wire budget. */
public final class ActivityLayoutBudgetTest {
    public static void main(String[] args) throws Exception {
        JSONArray nodes = new JSONArray();
        for (int i=0; i<12; i++) nodes.put(new JSONObject()
            .put("kind", i%3==0 ? "image" : "text")
            .put("x", .05*i).put("y", .2).put("width", .1).put("height", .2)
            .put("color", 4294967295L).put("size", 18).put("bold", true)
            .put(i%3==0 ? "imageRevision" : "text", i%3==0 ? "a".repeat(64) : "team-score-status-"+i)
            .put("image", "a".repeat(384)));
        Class<?> cls=Class.forName("app.droidmirror.bluetooth.bridge.ActivityLayoutBudget");
        cls.getMethod("fit", JSONArray.class, int.class).invoke(cls.getField("INSTANCE").get(null),nodes,2400);
        if(nodes.length()!=12 || nodes.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length>2400)
            throw new AssertionError("card was truncated or exceeded budget");
        for(int i=0;i<12;i++) {
            JSONObject n=nodes.getJSONObject(i);
            if(n.has("image") || !n.has(i%3==0 ? "imageRevision" : "text")) throw new AssertionError("lost content");
        }
        if(!nodes.getJSONObject(11).getString("text").equals("team-score-status-11")) throw new AssertionError("lost trailing status");
        JSONArray rich = new JSONArray();
        for(int i=0;i<32;i++) rich.put(new JSONObject().put("kind",i<2 ? "image" : "text")
            .put("sportsTeam",i==1 ? 2 : 1).put("sportsField",i<2 ? "logo" : "setScore")
            .put("text","Set score "+i).put("x",.5).put("y",.5).put("width",.2).put("height",.1)
            .put("size",14).put("color",4294967295L).put("bold",false));
        cls.getMethod("compactSports",JSONArray.class).invoke(cls.getField("INSTANCE").get(null),rich);
        cls.getMethod("fit",JSONArray.class,int.class).invoke(cls.getField("INSTANCE").get(null),rich,3400);
        if(rich.length()!=32 || rich.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length>3400)
            throw new AssertionError("rich match metadata exceeded the bounded frame");
        if(rich.getJSONObject(0).has("x") || !rich.getJSONObject(31).getString("text").equals("Set score 31"))
            throw new AssertionError("semantic compaction lost source content");
        System.out.println("PASS: complete custom card retained within budget");
    }
}
