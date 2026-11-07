package javax.microedition.lcdui;

/**
 * MIDP TextBox — shown natively as an iOS text-entry dialog (system keyboard).
 *
 * Display.setCurrent(textBox) → showNative() sends title/text/constraints/commands
 * to the native side (form type 3). When the user taps a command button, the
 * native side stores the typed text and posts the command; Display calls
 * syncFromNative() before firing the CommandListener, so getString() returns
 * what the user typed.
 */
public class TextBox extends Screen {
    private String text;
    private int maxSize;
    private int constraints;

    public TextBox(String title, String text, int maxSize, int constraints) {
        setTitle(title);
        this.maxSize = maxSize > 0 ? maxSize : 1;
        this.constraints = constraints;
        setString(text);
    }

    void showNative() {
        NativeBridge.formBegin(getTitle(), 3); // type 3 = textbox
        NativeBridge.formAddTextField("", text, maxSize, constraints);
        java.util.ArrayList<Command> cmds = getCommands();
        for (int i = 0; i < cmds.size(); i++) {
            Command c = cmds.get(i);
            NativeBridge.formAddCommand(c.getLabel(), c.getCommandType(), c.getPriority(), i);
        }
        NativeBridge.formShow();
    }

    /** Pull the text typed in the native dialog (if any). */
    void syncFromNative() {
        String typed = NativeBridge.takeTextResult(0);
        if (typed != null) setString(typed);
    }

    public String getString() { return text; }

    public void setString(String text) {
        String t = text != null ? text : "";
        if (t.length() > maxSize) t = t.substring(0, maxSize);
        this.text = t;
    }

    public int getChars(char[] data) {
        text.getChars(0, text.length(), data, 0);
        return text.length();
    }

    public void setChars(char[] data, int offset, int length) {
        setString(data == null ? "" : new String(data, offset, length));
    }

    public void insert(String src, int position) {
        if (src == null) return;
        int p = Math.max(0, Math.min(position, text.length()));
        setString(text.substring(0, p) + src + text.substring(p));
    }

    public void insert(char[] data, int offset, int length, int position) {
        insert(new String(data, offset, length), position);
    }

    public void delete(int offset, int length) {
        int start = Math.max(0, Math.min(offset, text.length()));
        int end = Math.max(start, Math.min(offset + length, text.length()));
        text = text.substring(0, start) + text.substring(end);
    }

    public int getMaxSize() { return maxSize; }

    public int setMaxSize(int maxSize) {
        this.maxSize = maxSize > 0 ? maxSize : 1;
        setString(text);
        return this.maxSize;
    }

    public int getConstraints() { return constraints; }
    public void setConstraints(int constraints) { this.constraints = constraints; }
    public int size() { return text.length(); }
    public int getCaretPosition() { return text.length(); }
    public void setInitialInputMode(String characterSubset) { }
}
