package android.content;
/** Persistence boundary used by the merged background-bridge settings. */
public interface SharedPreferences {
    boolean getBoolean(String key, boolean fallback);
    String getString(String key, String fallback);
    Editor edit();
    interface Editor {
        Editor putBoolean(String key, boolean value);
        Editor putString(String key, String value);
        boolean commit();
    }
}
