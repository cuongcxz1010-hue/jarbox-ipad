package javax.microedition.lcdui;

public class TextField extends Item {
    public static final int ANY = 0;
    public static final int EMAILADDR = 1;
    public static final int NUMERIC = 2;
    public static final int PHONENUMBER = 3;
    public static final int URL = 4;
    public static final int DECIMAL = 5;
    public static final int PASSWORD = 0x10000;
    public static final int UNEDITABLE = 0x20000;
    public static final int SENSITIVE = 0x40000;
    public static final int NON_PREDICTIVE = 0x80000;
    public static final int INITIAL_CAPS_WORD = 0x100000;
    public static final int INITIAL_CAPS_SENTENCE = 0x200000;
    public static final int CONSTRAINT_MASK = 0xFFFF;

    private final TextEditor editor;

    public TextField(String label, String text, int maxSize, int constraints) {
        setLabel(label);
        editor = new TextEditor(text, maxSize, constraints);
    }

    public String getString() { return editor.getString(); }
    public void setString(String text) { editor.setString(text); midpChanged(); }
    public int getChars(char[] data) { return editor.getChars(data); }
    public void setChars(char[] data, int offset, int length) { editor.setChars(data, offset, length); midpChanged(); }
    public void insert(String src, int position) { editor.insert(src, position); midpChanged(); }
    public void insert(char[] data, int offset, int length, int position) { editor.insert(data, offset, length, position); midpChanged(); }
    public void delete(int offset, int length) { editor.delete(offset, length); midpChanged(); }
    public int getMaxSize() { return editor.getMaxSize(); }
    public int setMaxSize(int maxSize) { int r = editor.setMaxSize(maxSize); midpChanged(); return r; }
    public int getConstraints() { return editor.getConstraints(); }
    public void setConstraints(int constraints) { editor.setConstraints(constraints); midpChanged(); }
    public int size() { return editor.size(); }
    public int getCaretPosition() { return editor.size(); }
    public void setInitialInputMode(String characterSubset) { }

    @Override
    void midpWrite(ScreenWriter out) {
        out.field("kind", "text");
        out.field("text", editor.getString());
        out.field("maxSize", editor.getMaxSize());
        out.field("constraints", editor.getConstraints());
    }

    @Override
    boolean midpNativeValue(String value) {
        if (value.equals(editor.getString())) return false;
        editor.setFromUser(value);
        return true;
    }
}
