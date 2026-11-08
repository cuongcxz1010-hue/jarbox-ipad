package javax.microedition.util;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Resources of the running game's JAR, for platform classes. Names are tried
 * exactly first, then ignoring case and with a guessed image extension,
 * which old games sometimes need.
 */
public final class GameResources {
    private static ZipFile zip;
    private static HashMap<String, String> lowerCaseNames;

    private GameResources() { }

    private static synchronized boolean open() {
        if (zip != null) return true;
        String path = System.getProperty("java.class.path");
        if (path == null) return false;
        try {
            zip = new ZipFile(path);
            HashMap<String, String> names = new HashMap<String, String>();
            for (Enumeration<? extends ZipEntry> e = zip.entries(); e.hasMoreElements(); ) {
                String n = e.nextElement().getName();
                names.put(n.toLowerCase(), n);
            }
            lowerCaseNames = names;
            return true;
        } catch (IOException ex) {
            System.out.println("[GameResources] cannot open " + path + ": " + ex);
            return false;
        }
    }

    private static String strip(String name) {
        String n = name;
        while (n.startsWith("/")) n = n.substring(1);
        return n;
    }

    /** The resource as a stream, or null when the JAR does not have it. */
    public static InputStream open(String name) {
        if (name == null || !open()) return null;
        String n = strip(name);
        synchronized (GameResources.class) {
            try {
                ZipEntry entry = zip.getEntry(n);
                if (entry == null) {
                    String actual = lowerCaseNames.get(n.toLowerCase());
                    if (actual != null) entry = zip.getEntry(actual);
                }
                if (entry == null && n.lastIndexOf('.') <= n.lastIndexOf('/')) {
                    String actual = lowerCaseNames.get(n.toLowerCase() + ".png");
                    if (actual != null) entry = zip.getEntry(actual);
                }
                if (entry == null) return null;
                InputStream in = zip.getInputStream(entry);
                ByteArrayOutputStream out = new ByteArrayOutputStream(4096);
                byte[] buffer = new byte[4096];
                int r;
                while ((r = in.read(buffer)) > 0) out.write(buffer, 0, r);
                in.close();
                return new ByteArrayInputStream(out.toByteArray());
            } catch (IOException e) {
                System.out.println("[GameResources] read failed for " + name + ": " + e);
                return null;
            }
        }
    }
}
