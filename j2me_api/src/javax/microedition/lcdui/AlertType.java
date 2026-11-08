package javax.microedition.lcdui;

public class AlertType {
    public static final AlertType ALARM = new AlertType();
    public static final AlertType CONFIRMATION = new AlertType();
    public static final AlertType ERROR = new AlertType();
    public static final AlertType INFO = new AlertType();
    public static final AlertType WARNING = new AlertType();

    protected AlertType() { }

    public boolean playSound(Display display) {
        if (display == null) throw new NullPointerException();
        NativeBridge.vibrate(this == ERROR || this == ALARM ? 300 : 80);
        return true;
    }
}
