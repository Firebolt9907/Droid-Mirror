package com.genymobile.scrcpy;

/** getevent -lt output: only contact starts count, never proximity, keys or releases. */
public final class RemoteUseTouch {
    public static boolean isContact(String line) {
        String[] fields = line.trim().split("\\s+");
        if (fields.length < 3) return false;
        String code = fields[fields.length - 2], value = fields[fields.length - 1];
        if ("BTN_TOUCH".equals(code)) return "DOWN".equals(value) || "00000001".equals(value);
        if (!"ABS_MT_TRACKING_ID".equals(code)) return false;
        try { return Long.parseLong(value, 16) < 0x80000000L; }
        catch (NumberFormatException ignored) { return false; }
    }
    private RemoteUseTouch() {}
}
