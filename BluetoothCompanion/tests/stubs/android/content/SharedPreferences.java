package android.content;
/** Persistence boundary used by the merged background-bridge settings. */
public interface SharedPreferences {
    boolean getBoolean(String key, boolean fallback);
    String getString(String key, String fallback);
    default boolean contains(String key) { return getString(key, null) != null; }
    default java.util.Set<String> getStringSet(String key, java.util.Set<String> fallback) { throw new UnsupportedOperationException(); }
    Editor edit();
    interface Editor {
        Editor putBoolean(String key, boolean value);
        Editor putString(String key, String value);
        default Editor clear() { throw new UnsupportedOperationException(); }
        default Editor putStringSet(String key, java.util.Set<String> value) { throw new UnsupportedOperationException(); }
        default Editor remove(String key) { throw new UnsupportedOperationException(); }
        boolean commit();
    }
}
