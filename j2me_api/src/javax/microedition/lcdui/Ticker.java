package javax.microedition.lcdui;

public class Ticker {
    private String text;

    public Ticker(String text) {
        if (text == null) throw new NullPointerException();
        this.text = text;
    }

    public void setString(String text) {
        if (text == null) throw new NullPointerException();
        this.text = text;
        Display.refreshCurrent();
    }

    public String getString() { return text; }
}
