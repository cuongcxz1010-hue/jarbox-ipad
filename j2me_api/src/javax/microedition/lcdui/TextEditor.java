package javax.microedition.lcdui;

/** The text model shared by TextField and TextBox. */
final class TextEditor {
    private String text;
    private int maxSize;
    private int constraints;

    TextEditor(String text, int maxSize, int constraints) {
        if (maxSize <= 0) throw new IllegalArgumentException();
        this.maxSize = maxSize;
        this.constraints = constraints;
        this.text = "";
        setString(text);
    }

    String getString() { return text; }

    void setString(String value) {
        String v = value == null ? "" : value;
        if (v.length() > maxSize) throw new IllegalArgumentException();
        text = v;
    }

    /** Text typed by the user: never rejected, only cut to the limit. */
    void setFromUser(String value) {
        text = value.length() > maxSize ? value.substring(0, maxSize) : value;
    }

    int getChars(char[] data) {
        if (data == null) throw new NullPointerException();
        if (data.length < text.length()) throw new ArrayIndexOutOfBoundsException();
        text.getChars(0, text.length(), data, 0);
        return text.length();
    }

    void setChars(char[] data, int offset, int length) {
        if (data == null) { setString(""); return; }
        setString(new String(data, offset, length));
    }

    void insert(String src, int position) {
        if (src == null) throw new NullPointerException();
        int p = position < 0 ? 0 : (position > text.length() ? text.length() : position);
        setString(text.substring(0, p) + src + text.substring(p));
    }

    void insert(char[] data, int offset, int length, int position) {
        insert(new String(data, offset, length), position);
    }

    void delete(int offset, int length) {
        if (offset < 0 || length < 0 || offset + length > text.length()) throw new StringIndexOutOfBoundsException();
        text = text.substring(0, offset) + text.substring(offset + length);
    }

    int getMaxSize() { return maxSize; }

    int setMaxSize(int size) {
        if (size <= 0) throw new IllegalArgumentException();
        maxSize = size;
        if (text.length() > size) text = text.substring(0, size);
        return size;
    }

    int getConstraints() { return constraints; }
    void setConstraints(int c) { constraints = c; }
    int size() { return text.length(); }
}
