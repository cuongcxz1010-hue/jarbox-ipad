package javax.microedition.lcdui;

import javax.microedition.lcdui.event.CanvasEvent;
import javax.microedition.lcdui.event.Event;
import javax.microedition.lcdui.event.EventFilter;
import javax.microedition.lcdui.keyboard.KeyMapper;

/**
 * Canvas with the event model of J2ME Loader: repaint() only records a dirty
 * area and queues one paint event; paint() and all input run on the event
 * thread; serviceRepaints() paints immediately but still serialized.
 */
public abstract class Canvas extends Displayable {
    public static final int UP = 1;
    public static final int DOWN = 6;
    public static final int LEFT = 2;
    public static final int RIGHT = 5;
    public static final int FIRE = 8;
    public static final int GAME_A = 9;
    public static final int GAME_B = 10;
    public static final int GAME_C = 11;
    public static final int GAME_D = 12;

    public static final int KEY_UP = -1;
    public static final int KEY_DOWN = -2;
    public static final int KEY_LEFT = -3;
    public static final int KEY_RIGHT = -4;
    public static final int KEY_FIRE = -5;
    public static final int KEY_SOFT_LEFT = -6;
    public static final int KEY_SOFT_RIGHT = -7;
    public static final int KEY_CLEAR = -8;
    public static final int KEY_SEND = -10;
    public static final int KEY_END = -11;

    public static final int KEY_NUM0 = 48;
    public static final int KEY_NUM1 = 49;
    public static final int KEY_NUM2 = 50;
    public static final int KEY_NUM3 = 51;
    public static final int KEY_NUM4 = 52;
    public static final int KEY_NUM5 = 53;
    public static final int KEY_NUM6 = 54;
    public static final int KEY_NUM7 = 55;
    public static final int KEY_NUM8 = 56;
    public static final int KEY_NUM9 = 57;
    public static final int KEY_STAR = 42;
    public static final int KEY_POUND = 35;

    private final PaintEvent paintEvent = new PaintEvent();
    /** Guards the screen buffer: paint and flushGraphics may come from different threads. */
    private final Object bufferLock = new Object();

    private long nativeContext;
    private Graphics graphics;
    private volatile boolean visible;
    private boolean sizeChangedCalled;
    private boolean fullScreen;

    private static int fpsLimit;
    private long lastFrameTime = System.currentTimeMillis();

    protected Canvas() { }

    /** Used by Nokia's FullCanvas. */
    protected Canvas(boolean fullScreen) { this.fullScreen = fullScreen; }

    public static void setLimitFps(int fps) { fpsLimit = fps; }
    public static int getLimitFps() { return fpsLimit; }

    // ------------------------------------------------------------
    // Painting
    // ------------------------------------------------------------

    protected abstract void paint(Graphics g);

    private void limitFps() {
        int limit = fpsLimit;
        if (limit <= 0) return;
        try {
            long millis = (1000 / limit) - (System.currentTimeMillis() - lastFrameTime);
            if (millis > 0) Thread.sleep(millis);
        } catch (InterruptedException e) {
            // keep going
        }
        lastFrameTime = System.currentTimeMillis();
    }

    public final void repaint() {
        repaint(0, 0, width, height);
    }

    public final void repaint(int x, int y, int w, int h) {
        limitFps();
        boolean post;
        synchronized (paintEvent) {
            post = paintEvent.invalidate(x, y, x + w, y + h) && !paintEvent.isPending;
            if (post) paintEvent.isPending = true;
        }
        if (post) Display.postEvent(paintEvent);
    }

    public final void serviceRepaints() {
        Display.getEventQueue().serviceRepaints(paintEvent);
    }

    private final class PaintEvent extends Event implements EventFilter {
        boolean isPending;
        private int left, top, right, bottom;

        /** Grow the dirty area; true when it was empty before. */
        boolean invalidate(int l, int t, int r, int b) {
            boolean empty = left >= right || top >= bottom;
            if (l < 0) l = 0;
            if (t < 0) t = 0;
            if (r > width) r = width;
            if (b > height) b = height;
            if (empty) {
                left = l; top = t; right = r; bottom = b;
            } else {
                if (l < left) left = l;
                if (t < top) top = t;
                if (r > right) right = r;
                if (b > bottom) bottom = b;
            }
            return empty;
        }

        public void process() {
            int l, t, r, b;
            synchronized (this) {
                isPending = false;
                l = left; t = top; r = right; b = bottom;
                left = top = right = bottom = 0;
            }
            if (l >= r || t >= b || !visible) return;
            paintNow(l, t, r - l, b - t);
        }

        public void recycle() { }
        public void enterQueue() { }
        public void leaveQueue() { }
        public boolean placeableAfter(Event event) { return event != this; }
        public boolean accept(Event event) { return event == this; }
    }

    private void paintNow(int x, int y, int w, int h) {
        synchronized (bufferLock) {
            if (nativeContext == 0) return;
            graphics.reset(x, y, w, h);
            try {
                paint(graphics);
            } catch (Throwable t) {
                System.out.println("[Canvas] Error in paint(): " + t);
                t.printStackTrace();
            }
            NativeBridge.flushToScreen(nativeContext);
        }
    }

    /** GameCanvas.flushGraphics: copy the off-screen image to the screen. */
    public void flushBuffer(Image image, int x, int y, int w, int h) {
        limitFps();
        if (w <= 0 || h <= 0 || x + w < 0 || y + h < 0 || x >= width || y >= height) return;
        synchronized (bufferLock) {
            if (nativeContext == 0 || !visible) return;
            graphics.reset(x, y, w, h);
            graphics.drawImage(image, 0, 0, Graphics.LEFT | Graphics.TOP);
            NativeBridge.flushToScreen(nativeContext);
        }
    }

    /** Siemens ExtendedImage: draw an image at a position and show it. */
    public void flushBuffer(Image image, int x, int y) {
        limitFps();
        synchronized (bufferLock) {
            if (nativeContext == 0 || !visible) return;
            graphics.reset(0, 0, width, height);
            graphics.drawImage(image, x, y, Graphics.LEFT | Graphics.TOP);
            NativeBridge.flushToScreen(nativeContext);
        }
    }

    // ------------------------------------------------------------
    // Show / hide (event thread)
    // ------------------------------------------------------------

    @Override
    void show() {
        synchronized (bufferLock) {
            if (nativeContext == 0) {
                nativeContext = NativeBridge.createContext(width, height);
                graphics = new Graphics(nativeContext, width, height);
            }
        }
        visible = true;
        refresh();
        NativeBridge.showCanvas();
        if (!sizeChangedCalled) {
            sizeChangedCalled = true;
            callSizeChanged();
        }
        try {
            doShowNotify();
        } catch (Throwable t) {
            System.out.println("[Canvas] Error in showNotify(): " + t);
        }
        repaint();
    }

    private void callSizeChanged() {
        try {
            doSizeChanged(width, height);
        } catch (Throwable t) {
            System.out.println("[Canvas] Error in sizeChanged(): " + t);
        }
    }

    @Override
    void hide() {
        if (!visible) return;
        visible = false;
        try {
            doHideNotify();
        } catch (Throwable t) {
            System.out.println("[Canvas] Error in hideNotify(): " + t);
        }
    }

    /** Publish the labels of the commands of this canvas (shown in the app menu). */
    @Override
    void refresh() {
        if (!visible) return;
        ScreenWriter out = new ScreenWriter();
        out.beginObject();
        out.field("kind", "canvas");
        out.commands("commands", getCommands());
        out.endObject();
        NativeBridge.setCanvasCommands(out.toString());
    }

    public boolean isShown() { return visible && super.isShown(); }

    public void setFullScreenMode(boolean mode) { fullScreen = mode; }

    public boolean isFullScreen() { return fullScreen; }

    // ------------------------------------------------------------
    // Capabilities
    // ------------------------------------------------------------

    public boolean hasPointerEvents() { return true; }
    public boolean hasPointerMotionEvents() { return true; }
    public boolean hasRepeatEvents() { return true; }
    public boolean isDoubleBuffered() { return true; }

    // ------------------------------------------------------------
    // Input
    // ------------------------------------------------------------

    protected void keyPressed(int keyCode) { }
    protected void keyReleased(int keyCode) { }
    protected void keyRepeated(int keyCode) { }
    protected void pointerPressed(int x, int y) { }
    protected void pointerReleased(int x, int y) { }
    protected void pointerDragged(int x, int y) { }
    protected void showNotify() { }
    protected void hideNotify() { }

    /** Native key code → event queue. */
    public void postKeyEvent(int type, int keyCode) {
        Display.postEvent(CanvasEvent.getInstance(this, type, KeyMapper.convertKeyCode(keyCode)));
    }

    public void postPointerEvent(int type, int x, int y) {
        Display.postEvent(CanvasEvent.getInstance(this, type, 0, (float) x, (float) y));
    }

    // Called by CanvasEvent on the event thread; GameCanvas overrides the key methods.
    public void doKeyPressed(int keyCode) { keyPressed(keyCode); }
    public void doKeyReleased(int keyCode) { keyReleased(keyCode); }
    public void doKeyRepeated(int keyCode) { keyRepeated(keyCode); }
    public void doPointerPressed(int x, int y) { pointerPressed(x, y); }
    public void doPointerDragged(int x, int y) { pointerDragged(x, y); }
    public void doPointerReleased(int x, int y) { pointerReleased(x, y); }
    public void doShowNotify() { showNotify(); }
    public void doHideNotify() { hideNotify(); }
    public void doSizeChanged(int w, int h) { sizeChanged(w, h); }

    public int getGameAction(int keyCode) {
        int action = KeyMapper.getGameAction(keyCode);
        if (action == Integer.MAX_VALUE) throw new IllegalArgumentException("unknown key code " + keyCode);
        return action;
    }

    public int getKeyCode(int gameAction) {
        int code = KeyMapper.getKeyCode(gameAction);
        if (code == Integer.MAX_VALUE) throw new IllegalArgumentException("unknown game action " + gameAction);
        return code;
    }

    public String getKeyName(int keyCode) {
        String name = KeyMapper.getKeyName(keyCode);
        if (name == null) throw new IllegalArgumentException("unknown key code " + keyCode);
        return name;
    }
}
