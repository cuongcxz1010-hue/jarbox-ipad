package javax.microedition.lcdui;

import java.util.ArrayList;

import javax.microedition.lcdui.event.CommandActionEvent;

/**
 * Base of everything that can be shown. Sizes are known from construction,
 * as on a real phone: games read getWidth() in their constructors.
 */
public abstract class Displayable {
    private String title;
    public int width = Display.getScreenWidth();
    public int height = Display.getScreenHeight();
    private final ArrayList<Command> commands = new ArrayList<Command>();
    private CommandListener commandListener;
    private Ticker ticker;
    /** A refresh of this screen is already queued on the event thread. */
    volatile boolean refreshPending;

    public void setTitle(String title) {
        this.title = title;
        midpContentChanged();
    }

    public String getTitle() { return title; }

    public int getWidth() { return width; }
    public int getHeight() { return height; }

    public void addCommand(Command cmd) {
        if (cmd == null) throw new NullPointerException();
        if (!commands.contains(cmd)) {
            commands.add(cmd);
            midpContentChanged();
        }
    }

    public void removeCommand(Command cmd) {
        if (commands.remove(cmd)) midpContentChanged();
    }

    public void setCommandListener(CommandListener listener) { commandListener = listener; }

    public ArrayList<Command> midpCommands() { return commands; }
    public CommandListener midpCommandListener() { return commandListener; }

    public void setTicker(Ticker ticker) {
        this.ticker = ticker;
        midpContentChanged();
    }

    public Ticker getTicker() { return ticker; }

    public boolean isShown() { return Display.isVisible(this); }

    protected void sizeChanged(int w, int h) { }

    /** Tell the platform that what this screen shows has changed. */
    void midpContentChanged() {
        Display.midpContentChanged(this);
    }

    /** Called on the event thread when this becomes the current screen. */
    abstract void midpShow();

    /** Called on the event thread when another screen replaces this one. */
    abstract void midpHide();

    /** Send the current content to the platform (event thread). */
    abstract void midpRefresh();

    /** Run the listener of the command with this position in midpCommands(). */
    public void midpFireCommand(int commandIndex) {
        if (commandListener != null && commandIndex >= 0 && commandIndex < commands.size()) {
            Display.postEvent(CommandActionEvent.getInstance(commandListener, commands.get(commandIndex), this));
        }
    }
}
