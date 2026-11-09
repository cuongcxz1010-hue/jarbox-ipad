package javax.microedition.lcdui;

public class Alert extends Screen {
    public static final int FOREVER = -2;
    public static final Command DISMISS_COMMAND = new Command("OK", Command.OK, 0);

    private static final int DEFAULT_TIMEOUT = 2000;

    private String text;
    private Image image;
    private AlertType type;
    private int timeout = DEFAULT_TIMEOUT;
    private Gauge indicator;
    private boolean explicitListener;
    Displayable nextDisplayable;

    public Alert(String title) { this(title, null, null, null); }

    public Alert(String title, String alertText, Image alertImage, AlertType alertType) {
        setTitle(title);
        this.text = alertText;
        this.image = alertImage;
        this.type = alertType;
    }

    public String getString() { return text; }
    public void setString(String str) { text = str; midpContentChanged(); }
    public Image getImage() { return image; }
    public void setImage(Image img) { image = img; midpContentChanged(); }
    public AlertType getType() { return type; }
    public void setType(AlertType type) { this.type = type; }
    public int getTimeout() { return timeout; }

    public void setTimeout(int time) {
        if (time <= 0 && time != FOREVER) throw new IllegalArgumentException();
        timeout = time;
    }

    public int getDefaultTimeout() { return DEFAULT_TIMEOUT; }
    public Gauge getIndicator() { return indicator; }
    public void setIndicator(Gauge indicator) { this.indicator = indicator; midpContentChanged(); }

    public void setCommandListener(CommandListener listener) {
        explicitListener = listener != null;
        super.setCommandListener(listener);
    }

    @Override
    void midpWrite(ScreenWriter out) {
        out.field("kind", "alert");
        out.field("text", text == null ? "" : text);
        out.image("image", image);
        // An alert with several commands stays until the user chooses one
        out.field("timeout", midpCommands().size() > 1 ? FOREVER : timeout);
        out.field("alertType", type == AlertType.ERROR ? "error" : type == AlertType.WARNING ? "warning"
                : type == AlertType.ALARM ? "alarm" : type == AlertType.CONFIRMATION ? "confirmation" : "info");
        if (indicator != null) {
            out.beginObjectField("indicator");
            out.field("max", indicator.getMaxValue());
            out.field("value", indicator.getValue());
            out.endObject();
        }
    }

    @Override
    public void midpFireCommand(int commandIndex) {
        if (explicitListener && !midpCommands().isEmpty()) {
            super.midpFireCommand(commandIndex);
        } else {
            dismiss();
        }
    }

    /** Timeout elapsed, or the implicit OK was pressed. */
    void dismiss() {
        if (explicitListener && midpCommandListener() != null) {
            midpCommandListener().commandAction(DISMISS_COMMAND, this);
        } else {
            Display.dismissAlert(this);
        }
    }
}
