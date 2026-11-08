package javax.microedition.lcdui;

/** Kept for games built against old stubs; MIDP 2.0 uses a Gauge as the indicator. */
public class Indicator extends Gauge {
    public Indicator(int maxValue, int initialValue) {
        super(null, false, maxValue, initialValue);
    }
}
