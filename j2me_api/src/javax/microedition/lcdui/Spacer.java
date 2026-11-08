package javax.microedition.lcdui;

public class Spacer extends Item {
    private int minWidth, minHeight;

    public Spacer(int minWidth, int minHeight) {
        setMinimumSize(minWidth, minHeight);
    }

    public void setMinimumSize(int w, int h) {
        if (w < 0 || h < 0) throw new IllegalArgumentException();
        minWidth = w;
        minHeight = h;
        changed();
    }

    public void setLabel(String label) { throw new IllegalStateException(); }
    public void addCommand(Command cmd) { throw new IllegalStateException(); }
    public void setDefaultCommand(Command cmd) { throw new IllegalStateException(); }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "spacer");
        out.field("width", minWidth);
        out.field("height", minHeight);
    }
}
