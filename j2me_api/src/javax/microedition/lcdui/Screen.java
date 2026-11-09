package javax.microedition.lcdui;

/** A high-level screen (Form, List, Alert, TextBox), drawn by the platform with native views. */
public abstract class Screen extends Displayable {

    private boolean shown;

    /** Describe this screen for the platform. */
    abstract void midpWrite(ScreenWriter out);

    @Override
    void midpShow() {
        shown = true;
        midpRefresh();
    }

    @Override
    void midpHide() {
        shown = false;
    }

    @Override
    void midpRefresh() {
        if (!shown) return;
        ScreenWriter out = new ScreenWriter();
        out.beginObject();
        midpWrite(out);
        out.field("title", getTitle());
        Ticker t = getTicker();
        if (t != null) out.field("ticker", t.getString());
        out.commands("commands", midpCommands());
        out.endObject();
        NativeBridge.showScreen(out.toString());
    }

    /** Apply a value entered natively for the element with this position. */
    void midpNativeValue(int index, String value) { }

    /** A row of a list was chosen. */
    void midpListSelect(int index) { }

    /** A command belonging to an item was chosen. */
    void midpItemCommand(int itemIndex, int commandIndex) { }
}
