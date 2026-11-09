package javax.microedition.lcdui;

import java.util.ArrayList;

import javax.microedition.lcdui.event.CommandActionEvent;

public abstract class Item {
    public static final int LAYOUT_DEFAULT = 0;
    public static final int LAYOUT_LEFT = 1;
    public static final int LAYOUT_RIGHT = 2;
    public static final int LAYOUT_CENTER = 3;
    public static final int LAYOUT_TOP = 0x10;
    public static final int LAYOUT_BOTTOM = 0x20;
    public static final int LAYOUT_VCENTER = 0x30;
    public static final int LAYOUT_NEWLINE_BEFORE = 0x100;
    public static final int LAYOUT_NEWLINE_AFTER = 0x200;
    public static final int LAYOUT_SHRINK = 0x400;
    public static final int LAYOUT_EXPAND = 0x800;
    public static final int LAYOUT_VSHRINK = 0x1000;
    public static final int LAYOUT_VEXPAND = 0x2000;
    public static final int LAYOUT_2 = 0x4000;

    public static final int PLAIN = 0;
    public static final int HYPERLINK = 1;
    public static final int BUTTON = 2;

    private String label;
    Form owner;
    private final ArrayList<Command> commands = new ArrayList<Command>();
    private ItemCommandListener commandListener;
    private Command defaultCommand;
    private int layout = LAYOUT_DEFAULT;
    private int preferredWidth = -1, preferredHeight = -1;

    public void setLabel(String label) { this.label = label; midpChanged(); }
    public String getLabel() { return label; }

    public void addCommand(Command cmd) {
        if (cmd == null) throw new NullPointerException();
        if (!commands.contains(cmd)) { commands.add(cmd); midpChanged(); }
    }

    public void removeCommand(Command cmd) {
        if (commands.remove(cmd)) midpChanged();
    }

    public void setItemCommandListener(ItemCommandListener l) { commandListener = l; }

    public void setDefaultCommand(Command cmd) {
        defaultCommand = cmd;
        if (cmd != null) addCommand(cmd);
        midpChanged();
    }

    public void setLayout(int layout) { this.layout = layout; midpChanged(); }
    public int getLayout() { return layout; }
    public int getMinimumWidth() { return 0; }
    public int getMinimumHeight() { return 0; }
    public int getPreferredWidth() { return preferredWidth; }
    public int getPreferredHeight() { return preferredHeight; }

    public void setPreferredSize(int width, int height) {
        preferredWidth = width;
        preferredHeight = height;
    }

    public void notifyStateChanged() {
        Form f = owner;
        if (f != null) f.midpNotifyItemState(this);
    }

    /** The content changed: redraw it if it is on screen. */
    void midpChanged() {
        Form f = owner;
        if (f != null) f.midpContentChanged();
    }

    final void midpWriteTo(ScreenWriter out) {
        out.beginObject();
        out.field("label", label);
        out.field("layout", layout);
        midpWrite(out);
        if (!commands.isEmpty()) out.commands("commands", commands);
        if (defaultCommand != null) out.field("defaultCommand", commands.indexOf(defaultCommand));
        out.endObject();
    }

    abstract void midpWrite(ScreenWriter out);

    /** Apply a value entered natively; return true when it was a real change. */
    boolean midpNativeValue(String value) { return false; }

    /** The command at this position in the item's list was chosen. */
    final void midpFireItemCommand(int index) {
        if (commandListener != null && index >= 0 && index < commands.size()) {
            Display.postEvent(CommandActionEvent.getInstance(commandListener, commands.get(index), this));
        }
    }
}
