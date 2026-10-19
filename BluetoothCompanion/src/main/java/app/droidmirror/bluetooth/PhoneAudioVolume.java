package app.droidmirror.bluetooth;

import android.content.Context;
import android.media.AudioManager;
import com.genymobile.scrcpy.FakeContext;
import java.lang.reflect.Method;

/** Shell-side media state only. Ringer, alarms, calls and DND are untouched. */
final class PhoneAudioVolume implements AudioVolumeLease.Volume {
    private final AudioManager manager;
    private final Method devices, lastAudible;
    PhoneAudioVolume() throws Exception {
        manager = (AudioManager) FakeContext.get().getSystemService(Context.AUDIO_SERVICE);
        if (manager == null) throw new IllegalStateException("Audio service unavailable");
        // Both methods exist on supported Android versions. The last audible
        // index preserves a muted phone's nonzero slider value (getStreamVolume
        // reports zero for a muted stream).
        devices = AudioManager.class.getMethod("getDevicesForStream", int.class);
        lastAudible = AudioManager.class.getMethod("getLastAudibleStreamVolume", int.class);
    }
    @Override public int route() throws Exception { return (Integer) devices.invoke(manager, AudioManager.STREAM_MUSIC); }
    @Override public int lastAudible() throws Exception { return (Integer) lastAudible.invoke(manager, AudioManager.STREAM_MUSIC); }
    @Override public boolean muted() { return manager.isStreamMute(AudioManager.STREAM_MUSIC); }
    @Override public void setVolume(int value) {
        manager.setStreamVolume(AudioManager.STREAM_MUSIC, Math.min(value, manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)), 0);
    }
    @Override public void setMuted(boolean value) {
        manager.adjustStreamVolume(AudioManager.STREAM_MUSIC, value ? AudioManager.ADJUST_MUTE : AudioManager.ADJUST_UNMUTE, 0);
    }
}
