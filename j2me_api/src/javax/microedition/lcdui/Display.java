package javax.microedition.lcdui;

import javax.microedition.lcdui.event.Event;
import javax.microedition.lcdui.event.EventQueue;
import javax.microedition.lcdui.event.RunnableEvent;
import javax.microedition.lcdui.event.SimpleEvent;
import javax.microedition.midlet.MIDlet;

/**
 * The current screen and the MIDP event thread. Every callback into the
 * MIDlet (paint, key and pointer events, commandAction, show/hide,
 * callSerially) runs on that one thread, so they never overlap, as MIDP
 * requires and as J2ME Loader does.
 */
public class Display {
    public static final int LIST_ELEMENT = 1;
    public static final int CHOICE_GROUP_ELEMENT = 2;
    public static final int ALERT = 3;
    public static final int COLOR_BACKGROUND = 0;
    public static final int COLOR_FOREGROUND = 1;
    public static final int COLOR_HIGHLIGHTED_BACKGROUND = 2;
    public static final int COLOR_HIGHLIGHTED_FOREGROUND = 3;
    public static final int COLOR_BORDER = 4;
    public static final int COLOR_HIGHLIGHTED_BORDER = 5;

    private static final EventQueue eventQueue = new EventQueue();
    private static Display instance;

    private static int screenWidth = 240;
    private static int screenHeight = 320;
    private static volatile boolean appVisible = true;

    static {
        screenWidth = intProperty("j2me.screen.width", 240);
        screenHeight = intProperty("j2me.screen.height", 320);
    }

    private static int intProperty(String key, int fallback) {
        String v = System.getProperty(key);
        if (v != null) {
            try {
                return Integer.parseInt(v);
            } catch (NumberFormatException e) {
                // keep the default
            }
        }
        return fallback;
    }

    private volatile Displayable current;
    private MIDlet midlet;

    private Display() { }

    public static synchronized Display getDisplay(MIDlet midlet) {
        if (instance == null) instance = new Display();
        if (midlet != null) instance.midlet = midlet;
        return instance;
    }

    public static EventQueue getEventQueue() { return eventQueue; }

    public static void postEvent(Event event) { eventQueue.postEvent(event); }

    public static int getScreenWidth() { return screenWidth; }
    public static int getScreenHeight() { return screenHeight; }

    // ------------------------------------------------------------
    // Current screen
    // ------------------------------------------------------------

    public void setCurrent(Displayable next) {
        if (next == null) return;
        if (next instanceof Alert) {
            showAlert((Alert) next, current);
            return;
        }
        switchTo(next);
    }

    public void setCurrent(Alert alert, Displayable nextDisplayable) {
        if (nextDisplayable == null || nextDisplayable instanceof Alert) throw new NullPointerException();
        showAlert(alert, nextDisplayable);
    }

    private void showAlert(Alert alert, Displayable after) {
        alert.nextDisplayable = after;
        switchTo(alert);
    }

    public void setCurrentItem(Item item) {
        if (item == null) throw new NullPointerException();
        if (item.owner == null) throw new IllegalStateException();
        setCurrent(item.owner);
    }

    public Displayable getCurrent() { return current; }

    private void switchTo(final Displayable next) {
        final Displayable previous = current;
        current = next;
        eventQueue.postEvent(new SimpleEvent() {
            public void process() {
                if (previous != null && previous != next) previous.midpHide();
                next.midpShow();
            }
        });
    }

    /** The alert's timeout ran out or its implicit OK was pressed. */
    static void dismissAlert(Alert alert) {
        Display d = instance;
        if (d != null && d.current == alert && alert.nextDisplayable != null) {
            d.switchTo(alert.nextDisplayable);
        }
    }

    public void callSerially(Runnable r) {
        if (r != null) eventQueue.postEvent(RunnableEvent.getInstance(r));
    }

    // ------------------------------------------------------------
    // Screen content updates
    // ------------------------------------------------------------

    private static final class RefreshEvent extends SimpleEvent {
        private final Displayable target;

        RefreshEvent(Displayable target) { this.target = target; }

        public void process() {
            target.refreshPending = false;
            target.midpRefresh();
        }
    }

    /** Coalesced: a burst of changes to one screen sends it to the platform once. */
    static void midpContentChanged(Displayable d) {
        Display display = instance;
        if (display == null || display.current != d || d.refreshPending) return;
        d.refreshPending = true;
        eventQueue.postEvent(new RefreshEvent(d));
    }

    static void refreshCurrent() {
        Display display = instance;
        if (display != null && display.current != null) midpContentChanged(display.current);
    }

    static boolean isVisible(Displayable d) {
        Display display = instance;
        return display != null && display.current == d && appVisible;
    }

    // ------------------------------------------------------------
    // Events coming from the platform (delivered by MIDletRunner)
    // ------------------------------------------------------------

    /** Application moved to the background or came back. */
    public void setAppVisible(boolean visible) {
        if (appVisible == visible) return;
        appVisible = visible;
        final Displayable shown = current;
        if (shown instanceof Canvas) {
            final Canvas canvas = (Canvas) shown;
            final boolean nowVisible = visible;
            eventQueue.postEvent(new SimpleEvent() {
                public void process() {
                    if (nowVisible) canvas.midpShow();
                    else canvas.midpHide();
                }
            });
        }
    }

    /** Is this application in the foreground? */
    public static boolean isAppVisible() { return appVisible; }

    public void postCommand(final int commandId) {
        final Displayable shown = current;
        if (shown != null) {
            eventQueue.postEvent(new SimpleEvent() {
                public void process() { shown.midpFireCommand(commandId); }
            });
        }
    }

    public void postListSelect(final int index) {
        final Displayable shown = current;
        if (shown instanceof Screen) {
            eventQueue.postEvent(new SimpleEvent() {
                public void process() { ((Screen) shown).midpListSelect(index); }
            });
        }
    }

    public void postAlertDismissed() {
        final Displayable shown = current;
        if (shown instanceof Alert) {
            eventQueue.postEvent(new SimpleEvent() {
                public void process() { ((Alert) shown).dismiss(); }
            });
        }
    }

    public void postItemValue(final int index, final String value) {
        final Displayable shown = current;
        if (shown instanceof Screen && value != null) {
            eventQueue.postEvent(new SimpleEvent() {
                public void process() { ((Screen) shown).midpNativeValue(index, value); }
            });
        }
    }

    public void postItemCommand(final int itemIndex, final int commandIndex) {
        final Displayable shown = current;
        if (shown instanceof Screen) {
            eventQueue.postEvent(new SimpleEvent() {
                public void process() { ((Screen) shown).midpItemCommand(itemIndex, commandIndex); }
            });
        }
    }

    public Displayable currentDisplayable() { return current; }

    public MIDlet currentMIDlet() { return midlet; }

    // ------------------------------------------------------------
    // Device properties
    // ------------------------------------------------------------

    public boolean isColor() { return true; }
    public int numColors() { return 16777216; }
    public int numAlphaLevels() { return 256; }
    public boolean flashBacklight(int duration) { return false; }

    public int getBestImageHeight(int imageType) {
        switch (imageType) {
            case LIST_ELEMENT: case CHOICE_GROUP_ELEMENT: return 16;
            case ALERT: return screenHeight / 2;
            default: throw new IllegalArgumentException();
        }
    }

    public int getBestImageWidth(int imageType) {
        switch (imageType) {
            case LIST_ELEMENT: case CHOICE_GROUP_ELEMENT: return 16;
            case ALERT: return screenWidth;
            default: throw new IllegalArgumentException();
        }
    }

    public int getBorderStyle(boolean highlighted) {
        return highlighted ? Graphics.SOLID : Graphics.DOTTED;
    }

    public int getColor(int colorSpecifier) {
        switch (colorSpecifier) {
            case COLOR_BACKGROUND: return 0xFFFFFF;
            case COLOR_FOREGROUND: return 0x000000;
            case COLOR_HIGHLIGHTED_BACKGROUND: return 0x000080;
            case COLOR_HIGHLIGHTED_FOREGROUND: return 0xFFFFFF;
            case COLOR_BORDER: return 0x808080;
            case COLOR_HIGHLIGHTED_BORDER: return 0x000080;
            default: throw new IllegalArgumentException();
        }
    }

    public boolean vibrate(int duration) {
        if (duration < 0) throw new IllegalArgumentException();
        NativeBridge.vibrate(duration);
        return true;
    }

    // ------------------------------------------------------------
    // Start and stop of the event thread
    // ------------------------------------------------------------

    public static void startEventThread() {
        eventQueue.startProcessing();
    }

    /** End of the session: stop dispatching and release the screen. */
    public static void shutdown() {
        eventQueue.stopProcessing();
        Display d = instance;
        if (d != null && d.current != null) {
            Displayable shown = d.current;
            d.current = null;
            try {
                shown.midpHide();
            } catch (Throwable t) {
                System.out.println("[Display] hide on shutdown: " + t);
            }
        }
        instance = null;
    }
}
