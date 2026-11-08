package javax.microedition.midlet;

import java.util.Map;

import javax.microedition.io.ConnectionNotFoundException;
import javax.microedition.shell.MIDletRunner;

public abstract class MIDlet {
    private static Map<String, String> properties;

    protected MIDlet() { }

    /** Manifest and JAD attributes (internal). */
    public static void initProps(Map<String, String> p) { properties = p; }

    public final String getAppProperty(String key) {
        if (key == null) throw new NullPointerException();
        return properties == null ? null : properties.get(key);
    }

    public final void notifyPaused() { MIDletRunner.midletPaused(); }

    public final void notifyDestroyed() { MIDletRunner.midletDestroyed(); }

    public final void resumeRequest() { MIDletRunner.resumeRequested(); }

    protected abstract void startApp() throws MIDletStateChangeException;

    protected abstract void pauseApp();

    protected abstract void destroyApp(boolean unconditional) throws MIDletStateChangeException;

    // Lifecycle dispatch for the runner, which lives in another package
    public final void callStartApp() throws MIDletStateChangeException { startApp(); }
    public final void callPauseApp() { pauseApp(); }
    public final void callDestroyApp(boolean unconditional) throws MIDletStateChangeException { destroyApp(unconditional); }

    public boolean platformRequest(String url) throws ConnectionNotFoundException {
        if (url == null || url.length() == 0) return false;
        javax.microedition.lcdui.NativeBridge.platformRequest(url);
        return false;
    }

    public final int checkPermission(String permission) { return 1; }
}
