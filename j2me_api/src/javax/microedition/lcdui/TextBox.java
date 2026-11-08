package javax.microedition.lcdui;

public class TextBox extends Screen {
    private final TextEditor editor;

    public TextBox(String title, String text, int maxSize, int constraints) {
        setTitle(title);
        editor = new TextEditor(text, maxSize, constraints);
    }

    public String getString() { return editor.getString(); }
    public void setString(String text) { editor.setString(text); contentChanged(); }
    public int getChars(char[] data) { return editor.getChars(data); }
    public void setChars(char[] data, int offset, int length) { editor.setChars(data, offset, length); contentChanged(); }
    public void insert(String src, int position) { editor.insert(src, position); contentChanged(); }
    public void insert(char[] data, int offset, int length, int position) { editor.insert(data, offset, length, position); contentChanged(); }
    public void delete(int offset, int length) { editor.delete(offset, length); contentChanged(); }
    public int getMaxSize() { return editor.getMaxSize(); }
    public int setMaxSize(int maxSize) { int r = editor.setMaxSize(maxSize); contentChanged(); return r; }
    public int getConstraints() { return editor.getConstraints(); }
    public void setConstraints(int constraints) { editor.setConstraints(constraints); contentChanged(); }
    public int size() { return editor.size(); }
    public int getCaretPosition() { return editor.size(); }
    public void setInitialInputMode(String characterSubset) { }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "textbox");
        out.field("text", editor.getString());
        out.field("maxSize", editor.getMaxSize());
        out.field("constraints", editor.getConstraints());
    }

    @Override
    void onNativeValue(int index, String value) {
        editor.setFromUser(value);
    }
}
