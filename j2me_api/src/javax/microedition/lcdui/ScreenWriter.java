package javax.microedition.lcdui;

import java.util.ArrayList;

/**
 * Small JSON writer: high-level screens are handed to the platform as one
 * JSON document, which the native side turns into views.
 */
final class ScreenWriter {
    private final StringBuffer out = new StringBuffer(512);
    private boolean first = true;

    private void comma() {
        if (!first) out.append(',');
        first = false;
    }

    void beginObject() { comma(); out.append('{'); first = true; }
    void endObject() { out.append('}'); first = false; }

    void beginObjectField(String name) { key(name); out.append('{'); first = true; }

    void beginArray(String name) { key(name); out.append('['); first = true; }
    void endArray() { out.append(']'); first = false; }

    private void key(String name) {
        comma();
        string(name);
        out.append(':');
    }

    private void string(String s) {
        out.append('"');
        for (int i = 0, n = s.length(); i < n; i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': out.append("\\\""); break;
                case '\\': out.append("\\\\"); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default:
                    if (c < 0x20) {
                        String hex = Integer.toHexString(c);
                        out.append("\\u");
                        for (int k = hex.length(); k < 4; k++) out.append('0');
                        out.append(hex);
                    } else {
                        out.append(c);
                    }
            }
        }
        out.append('"');
    }

    void field(String name, String value) {
        if (value == null) return;
        key(name);
        string(value);
    }

    void field(String name, int value) { key(name); out.append(value); }
    void field(String name, long value) { key(name); out.append(value); }
    void field(String name, boolean value) { key(name); out.append(value ? "true" : "false"); }

    void image(String name, Image image) {
        if (image == null) return;
        String encoded = NativeBridge.imagePngBase64(image.nativeHandle);
        if (encoded != null) field(name, encoded);
    }

    void commands(String name, ArrayList<Command> list) {
        beginArray(name);
        for (int i = 0; i < list.size(); i++) {
            Command c = list.get(i);
            beginObject();
            field("label", c.getLabel());
            field("longLabel", c.getLongLabel());
            field("type", c.getCommandType());
            field("priority", c.getPriority());
            field("id", i);
            endObject();
        }
        endArray();
    }

    public String toString() { return out.toString(); }
}
