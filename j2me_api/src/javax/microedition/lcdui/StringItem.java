package javax.microedition.lcdui;

public class StringItem extends Item {
    private String text;
    private final int appearanceMode;
    private Font font = Font.getDefaultFont();

    public StringItem(String label, String text) {
        this(label, text, PLAIN);
    }

    public StringItem(String label, String text, int appearanceMode) {
        if (appearanceMode < PLAIN || appearanceMode > BUTTON) throw new IllegalArgumentException();
        setLabel(label);
        this.text = text;
        this.appearanceMode = appearanceMode;
    }

    public String getText() { return text; }
    public void setText(String text) { this.text = text; changed(); }
    public int getAppearanceMode() { return appearanceMode; }
    public Font getFont() { return font; }
    public void setFont(Font font) { this.font = font != null ? font : Font.getDefaultFont(); changed(); }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "string");
        out.field("text", text == null ? "" : text);
        out.field("appearance", appearanceMode);
    }
}
