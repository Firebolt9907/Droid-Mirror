package app.droidmirror.wear;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.*;
import org.json.JSONObject;

/** Deliberately limited to privacy stop, batteries and Find my Mac. */
public final class MainActivity extends Activity {
    private LinearLayout content;
    private final Runnable render = this::render;
    private final Runnable refresh = new Runnable() {
        @Override public void run() { WatchState.request(MainActivity.this); WatchState.MAIN.postDelayed(this, 10_000); }
    };
    private String actionSession = "", actionLease = "";
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().getDecorView().setBackgroundColor(Color.BLACK);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true);
        content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); content.setGravity(Gravity.CENTER_HORIZONTAL);
        content.setPadding(dp(24),dp(30),dp(24),dp(36)); scroll.addView(content); setContentView(scroll);
        handleIntent(getIntent());
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},1);
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent); render(); }
    private void handleIntent(Intent intent) {
        if (NowBarPublisher.STOP.equals(intent.getAction())) {
            actionSession = intent.getStringExtra("session"); actionLease = intent.getStringExtra("lease");
        }
    }
    @Override protected void onResume() {
        super.onResume(); WatchState.observers.add(render); WatchState.MAIN.post(refresh); render(); NowBarPublisher.update(this);
    }
    @Override protected void onPause() {
        WatchState.MAIN.removeCallbacks(refresh); WatchState.observers.remove(render); super.onPause();
    }
    private void render() {
        if (actionSession != null && !actionSession.isEmpty()) {
            boolean matches = actionSession.equals(WatchState.session()) && WatchState.fresh()
                && actionLease != null && actionLease.equals(WatchState.state.optString("lease"));
            actionSession = ""; actionLease = ""; getIntent().setAction(null);
            if (matches) { WatchState.MAIN.post(() -> WatchState.command(this,"stop")); }
        }
        content.removeAllViews();
        label("DroidMirror",18,Color.WHITE,true);
        boolean active = !WatchState.session().isEmpty();
        label(active ? "Phone is being mirrored" : WatchState.fresh() ? "No active mirror" : "Connecting to phone",14,active ? 0xFFFFB4AB : 0xFFB9C4CE,false);
        button(active ? "End mirroring" : "Privacy stop", active && WatchState.pending.isEmpty(), 0xFF8F252B, () -> WatchState.command(this,"stop"));
        JSONObject state = WatchState.fresh() ? WatchState.state : new JSONObject();
        battery("Phone",state.optJSONObject("phone"));
        JSONObject mac = state.optJSONObject("mac");
        battery("Mac",mac);
        if (mac != null && !mac.optString("name").isEmpty()) label(mac.optString("name"),12,0xFFB9C4CE,false);
        button("Find my Mac",mac != null && !mac.optString("id").isEmpty() && WatchState.pending.isEmpty(),0xFF224A65,() -> WatchState.command(this,"find"));
        if (!WatchState.message.isEmpty()) label(WatchState.message,13,0xFFB9C4CE,false);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            label("Allow notifications for the Now Bar privacy shortcut.",12,0xFFFFD59C,false);
            button("Allow notifications",true,0xFF333333,() -> requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},1));
        }
    }
    private void battery(String name,JSONObject value) {
        int level = value == null ? -1 : value.optInt("level",-1);
        String detail = level >= 0 && level <= 100 ? level + "%" + (value.optBoolean("charging") ? " · charging" : "") : "Unavailable";
        label(name + "  " + detail,16,Color.WHITE,false);
    }
    private void label(String value,int size,int color,boolean bold) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(color); view.setGravity(Gravity.CENTER);
        view.setPadding(0,dp(6),0,dp(6)); if(bold) view.setTypeface(null,Typeface.BOLD);
        content.addView(view,new LinearLayout.LayoutParams(-1,-2));
    }
    private void button(String text,boolean enabled,int color,Runnable action) {
        Button view = new Button(this); view.setText(text); view.setAllCaps(false); view.setTextSize(15); view.setTextColor(Color.WHITE);
        view.setMinHeight(dp(52)); view.setEnabled(enabled); view.setAlpha(enabled ? 1f : .4f);
        GradientDrawable background = new GradientDrawable(); background.setColor(color); background.setCornerRadius(dp(28)); view.setBackground(background);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1,-2); params.setMargins(0,dp(6),0,dp(6));
        content.addView(view,params); view.setOnClickListener(v -> action.run());
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results) {
        super.onRequestPermissionsResult(request,permissions,results); render(); NowBarPublisher.update(this);
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
