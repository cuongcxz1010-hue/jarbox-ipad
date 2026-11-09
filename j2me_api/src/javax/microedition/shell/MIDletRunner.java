/*
 * MIDletRunner — launches and supervises one MIDlet.
 *
 * The MIDlet runs on its own thread ("MidletMain"), as in J2ME Loader, so a
 * startApp() that never returns does not stop screen updates or input. The
 * JVM's main thread becomes the input pump: it blocks until the platform has
 * something to deliver, so an idle game uses no CPU for polling.
 */
package javax.microedition.shell;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Display;
import javax.microedition.lcdui.Displayable;
import javax.microedition.lcdui.NativeBridge;
import javax.microedition.lcdui.event.CanvasEvent;
import javax.microedition.midlet.MIDlet;

public class MIDletRunner {

    // Event types of NativeBridge.waitInputEvent; keep in sync with j2me_input.h
    private static final int POINTER_PRESSED = 0, POINTER_DRAGGED = 1, POINTER_RELEASED = 2;
    private static final int KEY_PRESSED = 3, KEY_RELEASED = 4, KEY_REPEATED = 5;
    private static final int UI_COMMAND = 10, UI_LIST_SELECT = 11, UI_ALERT_DISMISSED = 12, UI_ITEM_VALUE = 13, UI_ITEM_COMMAND = 14;
    private static final int APP_FPS_OVERRIDE = 20, APP_BACKGROUND = 21, APP_FOREGROUND = 22;

    private static volatile boolean destroyed;
    private static volatile boolean paused;
    private static volatile MIDlet midlet;
    private static String midletClassName;
    private static boolean midpPauseApp;
    private static int settingsFps;

    public static void main(String[] args) {
        if (args == null || args.length < 1) {
            System.out.println("[MIDletRunner] Usage: MIDletRunner <midlet.jar> [ClassName]");
            return;
        }

        try {
            start(args[0], args.length > 1 ? args[1] : null);
        } catch (Throwable t) {
            System.out.println("[MIDletRunner] ERROR: " + t);
            t.printStackTrace();
            NativeBridge.reportFailure(t.toString());
            return;
        }

        pumpEvents();

        requestDestroy();
        Display.shutdown();
        System.out.println("[MIDletRunner] Session ended");
    }

    private static void start(String jarPath, String classOverride) throws Exception {
        System.out.println("[MIDletRunner] Loading: " + jarPath);
        Map<String, String> attrs = readManifest(jarPath);
        mergeJad(jarPath, attrs);

        midletClassName = classOverride != null && classOverride.length() > 0 ? classOverride : parseMIDletClassName(attrs);
        if (midletClassName == null) {
            throw new IllegalStateException("MIDlet-1 is missing from the manifest");
        }
        System.out.println("[MIDletRunner] MIDlet: " + attrs.get("MIDlet-Name") + " " + attrs.get("MIDlet-Version")
                + " (" + midletClassName + ")");
        MIDlet.initProps(attrs);

        String fps = System.getProperty("j2me.fps.limit");
        if (fps != null) {
            settingsFps = Integer.parseInt(fps);
            Canvas.setLimitFps(settingsFps);
        }
        midpPauseApp = "1".equals(System.getProperty("j2me.call.pauseapp"));

        Display.startEventThread();

        Thread main = new Thread(new Runnable() {
            public void run() { launch(); }
        }, "MidletMain");
        main.start();
    }

    private static void launch() {
        try {
            Class<?> clazz = ClassLoader.getSystemClassLoader().loadClass(midletClassName);
            MIDlet created = (MIDlet) clazz.newInstance();
            midlet = created;
            Display.getDisplay(created);
            System.out.println("[MIDletRunner] startApp()");
            created.midpStartApp();
        } catch (Throwable t) {
            System.out.println("[MIDletRunner] MIDlet failed to start: " + t);
            t.printStackTrace();
            NativeBridge.reportFailure(t.toString());
        }
    }

    /** Deliver platform events until the MIDlet ends or the user leaves the game. */
    private static void pumpEvents() {
        while (!destroyed) {
            int[] e = NativeBridge.waitInputEvent(500);
            if (NativeBridge.isStopRequested()) return;
            if (e == null) continue;
            try {
                dispatch(e);
            } catch (Throwable t) {
                System.out.println("[MIDletRunner] Event error: " + t);
            }
        }
    }

    private static void dispatch(int[] e) {
        int type = e[0];
        MIDlet m = midlet;
        Display display = Display.getDisplay(null);
        Displayable current = display.currentDisplayable();
        switch (type) {
            case POINTER_PRESSED:
                if (current instanceof Canvas) ((Canvas) current).midpPostPointer(CanvasEvent.POINTER_PRESSED, e[1], e[2]);
                break;
            case POINTER_DRAGGED:
                if (current instanceof Canvas) ((Canvas) current).midpPostPointer(CanvasEvent.POINTER_DRAGGED, e[1], e[2]);
                break;
            case POINTER_RELEASED:
                if (current instanceof Canvas) ((Canvas) current).midpPostPointer(CanvasEvent.POINTER_RELEASED, e[1], e[2]);
                break;
            case KEY_PRESSED:
                if (current instanceof Canvas) ((Canvas) current).midpPostKey(CanvasEvent.KEY_PRESSED, e[3]);
                break;
            case KEY_RELEASED:
                if (current instanceof Canvas) ((Canvas) current).midpPostKey(CanvasEvent.KEY_RELEASED, e[3]);
                break;
            case KEY_REPEATED:
                if (current instanceof Canvas) ((Canvas) current).midpPostKey(CanvasEvent.KEY_REPEATED, e[3]);
                break;
            case UI_COMMAND:
                display.postCommand(e[3]);
                break;
            case UI_LIST_SELECT:
                display.postListSelect(e[3]);
                break;
            case UI_ALERT_DISMISSED:
                display.postAlertDismissed();
                break;
            case UI_ITEM_VALUE:
                display.postItemValue(e[1], NativeBridge.takeTextResult(e[1]));
                break;
            case UI_ITEM_COMMAND:
                display.postItemCommand(e[1], e[2]);
                break;
            case APP_FPS_OVERRIDE:
                Canvas.setLimitFps(e[3] >= 0 ? e[3] : settingsFps);
                break;
            case APP_BACKGROUND:
                display.setAppVisible(false);
                if (midpPauseApp && m != null && !paused) {
                    paused = true;
                    runLifecycle(new Lifecycle() {
                        public void run(MIDlet target) { target.midpPauseApp(); }
                    });
                }
                break;
            case APP_FOREGROUND:
                display.setAppVisible(true);
                if (paused && m != null) resume();
                break;
            default:
                break;
        }
    }

    private interface Lifecycle {
        void run(MIDlet target) throws Exception;
    }

    private static void runLifecycle(final Lifecycle action) {
        final MIDlet target = midlet;
        if (target == null) return;
        Thread t = new Thread(new Runnable() {
            public void run() {
                try {
                    action.run(target);
                } catch (Throwable e) {
                    System.out.println("[MIDletRunner] Lifecycle error: " + e);
                }
            }
        }, "MidletLifecycle");
        t.start();
    }

    private static void resume() {
        paused = false;
        runLifecycle(new Lifecycle() {
            public void run(MIDlet target) throws Exception { target.midpStartApp(); }
        });
    }

    // ------------------------------------------------------------
    // Calls from the MIDlet
    // ------------------------------------------------------------

    public static void midletPaused() { paused = true; }

    public static void resumeRequested() {
        if (paused && !destroyed) resume();
    }

    public static void midletDestroyed() {
        destroyed = true;
        NativeBridge.wakeInput();
    }

    private static void requestDestroy() {
        final MIDlet target = midlet;
        if (destroyed || target == null) return;
        Thread t = new Thread(new Runnable() {
            public void run() {
                try {
                    target.midpDestroyApp(true);
                } catch (Throwable e) {
                    System.out.println("[MIDletRunner] destroyApp error: " + e);
                }
                destroyed = true;
            }
        }, "MidletDestroy");
        t.start();
        for (int i = 0; i < 30 && !destroyed; i++) {
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    // ------------------------------------------------------------
    // Descriptor files
    // ------------------------------------------------------------

    private static Map<String, String> readManifest(String jarPath) throws Exception {
        Map<String, String> result = new HashMap<String, String>();
        ZipFile zip = new ZipFile(jarPath);
        try {
            ZipEntry entry = zip.getEntry("META-INF/MANIFEST.MF");
            if (entry == null) {
                System.out.println("[MIDletRunner] WARNING: no MANIFEST.MF in the JAR");
                return result;
            }
            InputStream is = zip.getInputStream(entry);
            BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));
            String lastKey = null, line;
            while ((line = reader.readLine()) != null) {
                if (line.length() == 0) continue;
                if (line.charAt(0) == ' ' && lastKey != null) {
                    result.put(lastKey, result.get(lastKey) + line.substring(1));
                    continue;
                }
                int colon = line.indexOf(':');
                if (colon > 0) {
                    lastKey = line.substring(0, colon).trim();
                    result.put(lastKey, line.substring(colon + 1).trim());
                }
            }
            reader.close();
        } finally {
            zip.close();
        }
        return result;
    }

    /** A .jad saved next to the JAR takes precedence over the manifest, as on a phone. */
    private static void mergeJad(String jarPath, Map<String, String> attrs) {
        if (!jarPath.toLowerCase().endsWith(".jar")) return;
        java.io.File jad = new java.io.File(jarPath.substring(0, jarPath.length() - 4) + ".jad");
        if (!jad.exists()) return;
        try {
            BufferedReader reader = new BufferedReader(new InputStreamReader(new java.io.FileInputStream(jad), "UTF-8"));
            String line;
            while ((line = reader.readLine()) != null) {
                int colon = line.indexOf(':');
                if (colon <= 0) continue;
                String key = line.substring(0, colon).trim();
                if (key.startsWith("MIDlet-Jar-")) continue;
                attrs.put(key, line.substring(colon + 1).trim());
            }
            reader.close();
        } catch (Exception e) {
            System.out.println("[MIDletRunner] JAD read failed: " + e);
        }
    }

    private static String parseMIDletClassName(Map<String, String> attrs) {
        String first = attrs.get("MIDlet-1");
        if (first == null) {
            for (Map.Entry<String, String> entry : attrs.entrySet()) {
                String key = entry.getKey();
                if (key.startsWith("MIDlet-") && key.length() > 7 && Character.isDigit(key.charAt(7))) {
                    first = entry.getValue();
                    break;
                }
            }
        }
        if (first == null) return null;
        String[] parts = first.split(",");
        return parts[parts.length - 1].trim();
    }
}
