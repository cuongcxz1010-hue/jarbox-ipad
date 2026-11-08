package javax.microedition.lcdui;

public class Gauge extends Item {
    public static final int INDEFINITE = -1;
    public static final int CONTINUOUS_IDLE = 0;
    public static final int INCREMENTAL_IDLE = 1;
    public static final int CONTINUOUS_RUNNING = 2;
    public static final int INCREMENTAL_UPDATING = 3;

    private int maxValue, value;
    private final boolean interactive;

    public Gauge(String label, boolean interactive, int maxValue, int initialValue) {
        setLabel(label);
        this.interactive = interactive;
        this.maxValue = maxValue;
        this.value = initialValue;
    }

    public int getValue() { return value; }

    public void setValue(int v) {
        value = maxValue >= 0 && v > maxValue ? maxValue : (v < 0 && maxValue >= 0 ? 0 : v);
        changed();
    }

    public int getMaxValue() { return maxValue; }

    public void setMaxValue(int m) {
        maxValue = m;
        if (m >= 0 && value > m) value = m;
        changed();
    }

    public boolean isInteractive() { return interactive; }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "gauge");
        out.field("interactive", interactive);
        out.field("max", maxValue);
        out.field("value", value);
    }

    @Override
    boolean onNativeValue(String v) {
        try {
            int parsed = Integer.parseInt(v);
            if (parsed == value) return false;
            value = parsed;
            return true;
        } catch (NumberFormatException e) {
            return false;
        }
    }
}
