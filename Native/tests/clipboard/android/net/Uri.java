package android.net;
public final class Uri {
    private final String value;
    private Uri(String value) { this.value = value; }
    @Override public String toString() { return value; }
    public static final class Builder {
        private String scheme, authority;
        private final java.util.ArrayList<String> parts = new java.util.ArrayList<>();
        public Builder scheme(String value) { scheme = value; return this; }
        public Builder authority(String value) { authority = value; return this; }
        public Builder appendPath(String value) { parts.add(value); return this; }
        public Uri build() {
            try { return new Uri(new java.net.URI(scheme, authority, "/" + String.join("/", parts), null, null).toString()); }
            catch (java.net.URISyntaxException failure) { throw new IllegalArgumentException(failure); }
        }
    }
}
