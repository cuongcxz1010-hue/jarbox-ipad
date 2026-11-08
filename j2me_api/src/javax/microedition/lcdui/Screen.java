package javax.microedition.lcdui;

/** A high-level screen (Form, List, Alert, TextBox), drawn by the platform with native views. */
public abstract class Screen extends Displayable {

    private boolean shown;

    /** Describe this screen for the platform. */
    abstract void writeContent(ScreenWriter out);

    @Override
    void show() {
        shown = true;
        refresh();
    }

    @Override
    void hide() {
        shown = false;
    }

    @Override
    void refresh() {
        if (!shown) return;
        ScreenWriter out = new ScreenWriter();
        out.beginObject();
        writeContent(out);
        out.field("title", getTitle());
        Ticker t = getTicker();
        if (t != null) out.field("ticker", t.getString());
        out.commands("commands", getCommands());
        out.endObject();
        NativeBridge.showScreen(out.toString());
    }

    /** Apply a value entered natively for the element with this position. */
    void onNativeValue(int index, String value) { }

    /** A row of a list was chosen. */
    void onListSelect(int index) { }

    /** A command belonging to an item was chosen. */
    void onItemCommand(int itemIndex, int commandIndex) { }
}
