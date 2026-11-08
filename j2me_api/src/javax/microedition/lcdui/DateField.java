package javax.microedition.lcdui;

import java.util.Date;
import java.util.TimeZone;

public class DateField extends Item {
    public static final int DATE = 1;
    public static final int TIME = 2;
    public static final int DATE_TIME = 3;

    private Date date;
    private int mode;

    public DateField(String label, int mode) { this(label, mode, null); }

    public DateField(String label, int mode, TimeZone timeZone) {
        if (mode < DATE || mode > DATE_TIME) throw new IllegalArgumentException();
        setLabel(label);
        this.mode = mode;
    }

    public Date getDate() { return date; }
    public void setDate(Date date) { this.date = date; changed(); }
    public int getInputMode() { return mode; }

    public void setInputMode(int mode) {
        if (mode < DATE || mode > DATE_TIME) throw new IllegalArgumentException();
        this.mode = mode;
        changed();
    }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "date");
        out.field("mode", mode);
        if (date != null) out.field("value", date.getTime());
    }

    @Override
    boolean onNativeValue(String v) {
        try {
            date = new Date(Long.parseLong(v));
            return true;
        } catch (NumberFormatException e) {
            return false;
        }
    }
}
