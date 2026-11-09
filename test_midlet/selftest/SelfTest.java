import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Calendar;
import java.util.Date;
import java.util.Enumeration;
import java.util.Hashtable;
import java.util.Random;
import java.util.Timer;
import java.util.TimerTask;
import java.util.Vector;

import javax.microedition.io.Connector;
import javax.microedition.io.Datagram;
import javax.microedition.io.HttpConnection;
import javax.microedition.io.ServerSocketConnection;
import javax.microedition.io.SocketConnection;
import javax.microedition.io.StreamConnection;
import javax.microedition.io.UDPDatagramConnection;
import javax.microedition.lcdui.Alert;
import javax.microedition.lcdui.AlertType;
import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.ChoiceGroup;
import javax.microedition.lcdui.Choice;
import javax.microedition.lcdui.Command;
import javax.microedition.lcdui.CommandListener;
import javax.microedition.lcdui.DateField;
import javax.microedition.lcdui.Display;
import javax.microedition.lcdui.Displayable;
import javax.microedition.lcdui.Font;
import javax.microedition.lcdui.Form;
import javax.microedition.lcdui.Gauge;
import javax.microedition.lcdui.Graphics;
import javax.microedition.lcdui.Image;
import javax.microedition.lcdui.ImageItem;
import javax.microedition.lcdui.List;
import javax.microedition.lcdui.Spacer;
import javax.microedition.lcdui.StringItem;
import javax.microedition.lcdui.TextBox;
import javax.microedition.lcdui.TextField;
import javax.microedition.lcdui.game.GameCanvas;
import javax.microedition.lcdui.game.LayerManager;
import javax.microedition.lcdui.game.Sprite;
import javax.microedition.lcdui.game.TiledLayer;
import javax.microedition.media.Manager;
import javax.microedition.media.Player;
import javax.microedition.media.control.VolumeControl;
import javax.microedition.midlet.MIDlet;
import javax.microedition.rms.RecordEnumeration;
import javax.microedition.rms.RecordStore;
import javax.microedition.rms.RecordStoreNotFoundException;

/**
 * Automatic conformance checks: JVM behaviour, MIDP API, graphics pixel rules,
 * threads, RMS, networking over loopback and the event model. Every check
 * prints one line; the last line is a summary. Runs on the desktop host and in
 * the iOS Simulator.
 */
public class SelfTest extends MIDlet {
    private int passed, failed;
    private Display display;
    private final StringBuffer shown = new StringBuffer();

    private void check(String name, boolean ok) {
        if (ok) passed++; else failed++;
        System.out.println("[TEST] " + (ok ? "PASS " : "FAIL ") + name);
    }

    private void check(String name, int actual, int expected) {
        boolean ok = actual == expected;
        if (ok) passed++; else failed++;
        System.out.println("[TEST] " + (ok ? "PASS " : "FAIL ") + name + (ok ? "" : " (got " + actual + ", expected " + expected + ")"));
    }

    private void section(String name, Runnable body) {
        try {
            body.run();
        } catch (Throwable t) {
            failed++;
            System.out.println("[TEST] FAIL " + name + " threw " + t);
            t.printStackTrace();
        }
    }

    protected void startApp() {
        display = Display.getDisplay(this);
        Thread t = new Thread(new Runnable() {
            public void run() { runAll(); }
        }, "SelfTest");
        t.start();
    }

    protected void pauseApp() { }
    protected void destroyApp(boolean unconditional) { }

    private void runAll() {
        section("vm", new Runnable() { public void run() { testVm(); } });
        section("old bytecode", new Runnable() { public void run() { testOldBytecode(); } });
        section("strings", new Runnable() { public void run() { testStrings(); } });
        section("collections", new Runnable() { public void run() { testCollections(); } });
        section("threads", new Runnable() { public void run() { testThreads(); } });
        section("gc", new Runnable() { public void run() { testGc(); } });
        section("rms", new Runnable() { public void run() { testRms(); } });
        section("image", new Runnable() { public void run() { testImage(); } });
        section("graphics", new Runnable() { public void run() { testGraphics(); } });
        section("transforms", new Runnable() { public void run() { testTransforms(); } });
        section("game", new Runnable() { public void run() { testGameApi(); } });
        section("font", new Runnable() { public void run() { testFont(); } });
        section("media", new Runnable() { public void run() { testMedia(); } });
        section("tcp", new Runnable() { public void run() { testTcp(); } });
        section("udp", new Runnable() { public void run() { testUdp(); } });
        section("http", new Runnable() { public void run() { testHttp(); } });
        section("events", new Runnable() { public void run() { testEvents(); } });
        section("screens", new Runnable() { public void run() { testScreens(); } });
        section("properties", new Runnable() { public void run() { testProperties(); } });
        section("digest", new Runnable() { public void run() { testDigest(); } });
        section("https", new Runnable() { public void run() { probeHttps(); } });

        System.out.println("[SELFTEST] passed=" + passed + " failed=" + failed);
        new Report().show();
    }

    /** Leaves the result on the screen for screenshots. */
    private final class Report extends Canvas {
        void show() { display.setCurrent(this); }

        protected void paint(Graphics g) {
            g.setColor(failed == 0 ? 0x006000 : 0x800000);
            g.fillRect(0, 0, getWidth(), getHeight());
            g.setColor(0xFFFFFF);
            g.drawString("SelfTest", 4, 4, Graphics.TOP | Graphics.LEFT);
            g.drawString("passed " + passed, 4, 34, Graphics.TOP | Graphics.LEFT);
            g.drawString("failed " + failed, 4, 64, Graphics.TOP | Graphics.LEFT);
        }
    }

    // ------------------------------------------------------------
    // JVM
    // ------------------------------------------------------------

    private static int depth(int n) { return n == 0 ? 0 : 1 + depth(n - 1); }

    interface Shape { int area(); }
    static class Square implements Shape { int s; Square(int s) { this.s = s; } public int area() { return s * s; } }
    static class Cube extends Square { Cube(int s) { super(s); } public int area() { return 6 * super.area(); } }
    static int initOrder;
    static class Lazy { static int value = ++initOrder * 7; }

    private static int tryFinally() {
        int x = 1;
        try {
            x = 2;
            throw new RuntimeException();
        } catch (RuntimeException e) {
            x = 3;
            return x;
        } finally {
            x = 4;
        }
    }

    private void testVm() {
        check("int overflow", Integer.MAX_VALUE + 1, Integer.MIN_VALUE);
        check("int div truncates", -7 / 2, -3);
        check("int rem sign", -7 % 3, -1);
        check("int shift masks", 1 << 33, 2);
        check("unsigned shift", -1 >>> 28, 15);
        check("long multiply", (int) ((123456789012L * 3L) % 1000L), 36);
        check("long shift", (int) (1L << 40 >> 38), 4);
        check("long compare", Long.MIN_VALUE < Long.MAX_VALUE);
        check("float to int", (int) 3.99f, 3);
        check("float nan to int", (int) Float.NaN, 0);
        check("float huge to int", (int) 1e30f, Integer.MAX_VALUE);
        check("double to long", (int) ((long) 1e10 / 1000000L), 10000);
        check("float arithmetic", Math.abs(0.1f + 0.2f - 0.3f) < 1e-6f);
        check("double arithmetic", Math.abs(Math.sqrt(2.0) * Math.sqrt(2.0) - 2.0) < 1e-12);
        check("char arithmetic", (char) ('a' + 1) == 'b');
        check("byte cast", (byte) 200, -56);
        check("short cast", (short) 70000, 4464);

        try { int[] a = new int[2]; a[2] = 1; check("array bounds", false); }
        catch (ArrayIndexOutOfBoundsException e) { check("array bounds", true); }
        try { int z = 0; int y = 5 / z; check("div zero", y == -1); }
        catch (ArithmeticException e) { check("div zero", true); }
        try { Object o = null; o.hashCode(); check("null pointer", false); }
        catch (NullPointerException e) { check("null pointer", true); }
        try { Object o = "s"; Integer i = (Integer) o; check("class cast", i == null); }
        catch (ClassCastException e) { check("class cast", true); }
        try { Object[] a = new String[1]; a[0] = new Integer(1); check("array store", false); }
        catch (ArrayStoreException e) { check("array store", true); }
        try { int[] a = new int[-1]; check("negative size", a == null); }
        catch (NegativeArraySizeException e) { check("negative size", true); }

        check("finally", tryFinally(), 3);
        check("recursion", depth(2000), 2000);
        check("virtual dispatch", new Cube(2).area(), 24);
        Shape s = new Square(3);
        check("interface dispatch", s.area(), 9);
        check("instanceof", s instanceof Square && !(s instanceof Cube));
        check("static init once", Lazy.value + Lazy.value, 14);
        int[][] grid = new int[3][4];
        grid[2][3] = 9;
        check("multi array", grid[2][3] + grid.length + grid[0].length, 16);
        byte[] big = new byte[70000];
        big[69999] = 7;
        check("wide index", big[69999], 7);
        check("switch sparse", sparse(1000) + sparse(3) + sparse(77), 1110);
        check("switch dense", dense(0) + dense(2) + dense(9), 21);
        check("math", Math.max(3, 9) - Math.min(3, 9) + Math.abs(-2), 8);
        long t0 = System.currentTimeMillis();
        check("time", t0 > 1000000000000L);
    }

    private static int sparse(int v) {
        switch (v) {
            case 3: return 10;
            case 77: return 100;
            case 1000: return 1000;
            default: return 0;
        }
    }

    private static int dense(int v) {
        switch (v) {
            case 0: return 1;
            case 1: return 2;
            case 2: return 20;
            default: return 0;
        }
    }

    /** Classes compiled by old javac use jsr/ret and class file version 45. */
    private void testOldBytecode() {
        check("jsr/ret class file v45", OldCode.compute(), 42);
    }

    // ------------------------------------------------------------
    // Text
    // ------------------------------------------------------------

    private void testStrings() {
        String vn = "Tiếng Việt đẹp";
        try {
            byte[] utf = vn.getBytes("UTF-8");
            check("utf8 roundtrip", new String(utf, "UTF-8").equals(vn));
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            DataOutputStream out = new DataOutputStream(bos);
            out.writeUTF(vn);
            out.writeInt(0x12345678);
            out.writeLong(-2L);
            out.writeShort(-3);
            out.writeBoolean(true);
            out.writeFloat(1.5f);
            out.writeDouble(2.5);
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(bos.toByteArray()));
            check("writeUTF", in.readUTF().equals(vn));
            check("readInt", in.readInt(), 0x12345678);
            check("readLong", in.readLong() == -2L);
            check("readShort", in.readShort(), -3);
            check("readBoolean", in.readBoolean());
            check("readFloat", in.readFloat() == 1.5f);
            check("readDouble", in.readDouble() == 2.5);
        } catch (IOException e) {
            check("io " + e, false);
        }
        check("substring", "hello".substring(1, 3).equals("el"));
        check("indexOf", "abcabc".lastIndexOf('b'), 4);
        check("trim", " x ".trim().length(), 1);
        check("case", "AbC".toLowerCase().equals("abc") && "AbC".toUpperCase().equals("ABC"));
        check("replace", "a-b".replace('-', '+').equals("a+b"));
        check("parseInt", Integer.parseInt("-123"), -123);
        check("parseInt radix", Integer.parseInt("ff", 16), 255);
        check("toHex", Integer.toHexString(255).equals("ff"));
        check("long string", Long.parseLong("9000000000") == 9000000000L);
        check("float string", Float.parseFloat("1.25") == 1.25f && Double.parseDouble("2.5") == 2.5);
        StringBuffer sb = new StringBuffer("ab");
        sb.append(1).append('c').append(true).insert(0, "x").setCharAt(1, 'A');
        sb.deleteCharAt(0);
        check("StringBuffer", sb.toString().equals("Ab1ctrue"));
        check("string switch hash", "abc".hashCode(), 96354);
    }

    private void testCollections() {
        Vector v = new Vector();
        v.addElement("a");
        v.addElement("b");
        v.insertElementAt("c", 1);
        v.removeElement("a");
        check("Vector", v.size() == 2 && v.elementAt(0).equals("c"));
        Hashtable h = new Hashtable();
        h.put("k", new Integer(1));
        h.put("k2", new Integer(2));
        int sum = 0;
        for (Enumeration e = h.elements(); e.hasMoreElements(); ) sum += ((Integer) e.nextElement()).intValue();
        check("Hashtable", sum, 3);
        Random r = new Random(1234);
        check("Random is seeded", r.nextInt() == new Random(1234).nextInt());
        Calendar c = Calendar.getInstance();
        c.setTime(new Date(0L));
        check("Calendar", c.get(Calendar.YEAR) >= 1969);
    }

    // ------------------------------------------------------------
    // Threads and memory
    // ------------------------------------------------------------

    private volatile int threadValue;
    private final Object monitor = new Object();
    private boolean signalled;

    private void testThreads() {
        Thread t = new Thread(new Runnable() {
            public void run() { threadValue = 7; }
        });
        t.start();
        try { t.join(); } catch (InterruptedException e) { }
        check("thread join", threadValue, 7);

        Thread waiter = new Thread(new Runnable() {
            public void run() {
                try { Thread.sleep(30); } catch (InterruptedException e) { }
                synchronized (monitor) {
                    signalled = true;
                    monitor.notifyAll();
                }
            }
        });
        waiter.start();
        synchronized (monitor) {
            long until = System.currentTimeMillis() + 3000;
            while (!signalled && System.currentTimeMillis() < until) {
                try { monitor.wait(500); } catch (InterruptedException e) { }
            }
        }
        check("wait/notify", signalled);

        final int[] counter = new int[1];
        Thread[] workers = new Thread[4];
        for (int i = 0; i < 4; i++) {
            workers[i] = new Thread(new Runnable() {
                public void run() {
                    for (int k = 0; k < 2000; k++) synchronized (counter) { counter[0]++; }
                }
            });
            workers[i].start();
        }
        for (int i = 0; i < 4; i++) try { workers[i].join(); } catch (InterruptedException e) { }
        check("synchronized counter", counter[0], 8000);

        final int[] ticks = new int[1];
        Timer timer = new Timer();
        timer.schedule(new TimerTask() {
            public void run() { ticks[0]++; }
        }, 10, 20);
        try { Thread.sleep(150); } catch (InterruptedException e) { }
        timer.cancel();
        check("Timer ticks", ticks[0] >= 3);

        long a = System.currentTimeMillis();
        try { Thread.sleep(50); } catch (InterruptedException e) { }
        check("sleep", System.currentTimeMillis() - a >= 45);
    }

    private void testGc() {
        Object[] keep = new Object[64];
        for (int round = 0; round < 40; round++) {
            for (int i = 0; i < keep.length; i++) keep[i] = new byte[32 * 1024];
        }
        check("allocate 80 MB in chunks", keep[63] != null);
        Runtime rt = Runtime.getRuntime();
        check("memory info", rt.totalMemory() > 0 && rt.freeMemory() >= 0);
        System.gc();
        check("gc returns", true);
    }

    // ------------------------------------------------------------
    // RMS
    // ------------------------------------------------------------

    private void testRms() {
        try {
            try { RecordStore.deleteRecordStore("selftest"); } catch (RecordStoreNotFoundException e) { }
            try {
                RecordStore.openRecordStore("selftest", false);
                check("open missing store fails", false);
            } catch (RecordStoreNotFoundException e) {
                check("open missing store fails", true);
            }
            RecordStore rs = RecordStore.openRecordStore("selftest", true);
            byte[] a = {1, 2, 3}, b = {4, 5};
            int id1 = rs.addRecord(a, 0, 3);
            int id2 = rs.addRecord(b, 0, 2);
            check("record ids", id1 == 1 && id2 == 2);
            check("num records", rs.getNumRecords(), 2);
            check("record size", rs.getRecordSize(id1), 3);
            rs.setRecord(id1, new byte[]{9}, 0, 1);
            byte[] read = rs.getRecord(id1);
            check("setRecord", read.length == 1 && read[0] == 9);
            rs.deleteRecord(id2);
            check("deleteRecord", rs.getNumRecords(), 1);
            RecordEnumeration en = rs.enumerateRecords(null, null, false);
            check("enumerate", en.numRecords(), 1);
            int id3 = rs.addRecord(new byte[]{7}, 0, 1);
            check("ids never reused", id3, 3);
            rs.closeRecordStore();
            rs = RecordStore.openRecordStore("selftest", false);
            check("persisted", rs.getRecord(3)[0], 7);
            rs.closeRecordStore();
            String[] names = RecordStore.listRecordStores();
            boolean found = false;
            for (int i = 0; names != null && i < names.length; i++) if (names[i].equals("selftest")) found = true;
            check("list stores", found);
            RecordStore.deleteRecordStore("selftest");
            check("delete store", true);
        } catch (Exception e) {
            check("rms " + e, false);
        }
    }

    // ------------------------------------------------------------
    // Images and pixels
    // ------------------------------------------------------------

    private int px(Image img, int x, int y) {
        int[] out = new int[1];
        img.getRGB(out, 0, 1, x, y, 1, 1);
        return out[0];
    }

    private void testImage() {
        Image m = Image.createImage(10, 10);
        check("mutable white", px(m, 5, 5), 0xFFFFFFFF);
        check("mutable flag", m.isMutable());

        int[] rgb = {0xFF112233, 0x00000000, 0x80FF0000, 0xFFFFFFFF};
        Image a = Image.createRGBImage(rgb, 2, 2, true);
        check("rgb opaque", px(a, 0, 0), 0xFF112233);
        check("rgb transparent", px(a, 1, 0) >>> 24, 0);
        int half = px(a, 0, 1);
        check("rgb half alpha", (half >>> 24) >= 0x7E && (half >>> 24) <= 0x81 && ((half >> 16) & 0xFF) > 0xF0);
        check("rgb immutable", !a.isMutable());
        Image noAlpha = Image.createRGBImage(rgb, 2, 2, false);
        check("alpha ignored", px(noAlpha, 1, 0), 0xFF000000);

        // Sub-image keeps transparency
        Image sub = Image.createImage(a, 1, 0, 1, 2, Sprite.TRANS_NONE);
        check("subimage size", sub.getWidth() * 10 + sub.getHeight(), 12);
        check("subimage alpha", px(sub, 0, 0) >>> 24, 0);

        try {
            InputStream in = getClass().getResourceAsStream("/test.png");
            check("resource found", in != null);
            Image png = Image.createImage("/test.png");
            check("png size", png.getWidth() * 100 + png.getHeight(), 406);
            check("png opaque pixel", px(png, 0, 0), 0xFFFF0000);
            check("png transparent pixel", px(png, 3, 5) >>> 24, 0);
        } catch (IOException e) {
            check("png " + e, false);
        }
        try {
            Image.createImage("/missing.png");
            check("missing resource", false);
        } catch (IOException e) {
            check("missing resource", true);
        }
        try {
            m = Image.createImage(new byte[]{1, 2, 3}, 0, 3);
            check("bad data", false);
        } catch (IllegalArgumentException e) {
            check("bad data", true);
        }
        try {
            a.getGraphics();
            check("immutable graphics refused", false);
        } catch (IllegalStateException e) {
            check("immutable graphics refused", true);
        }
    }

    private void testGraphics() {
        Image img = Image.createImage(40, 40);
        Graphics g = img.getGraphics();
        check("default clip", g.getClipWidth() * 100 + g.getClipHeight(), 4040);

        g.setColor(0xFF0000);
        g.fillRect(2, 3, 4, 5);
        check("fillRect inside", px(img, 5, 7), 0xFFFF0000);
        check("fillRect right edge", px(img, 6, 7), 0xFFFFFFFF);
        check("fillRect bottom edge", px(img, 5, 8), 0xFFFFFFFF);

        g.setColor(0x00FF00);
        g.drawRect(10, 10, 3, 2);
        check("drawRect far corner included", px(img, 13, 12), 0xFF00FF00);
        check("drawRect beyond", px(img, 14, 12), 0xFFFFFFFF);
        check("drawRect hollow", px(img, 11, 11), 0xFFFFFFFF);

        g.setColor(0x0000FF);
        g.drawLine(20, 20, 24, 20);
        check("line end included", px(img, 24, 20), 0xFF0000FF);
        g.drawLine(25, 25, 25, 25);
        check("single point line", px(img, 25, 25), 0xFF0000FF);

        // Clip and translate
        g.setColor(0x123456);
        g.translate(5, 5);
        check("translate", g.getTranslateX() * 100 + g.getTranslateY(), 505);
        g.setClip(0, 0, 2, 2);
        check("clip relative", g.getClipX(), 0);
        g.fillRect(0, 0, 30, 30);
        check("clip limits", px(img, 6, 6), 0xFF123456);
        check("clip excludes", px(img, 7, 7), 0xFFFFFFFF);
        g.clipRect(1, 1, 10, 10);
        check("clipRect intersects", g.getClipWidth() * 10 + g.getClipHeight(), 11);
        g.translate(-5, -5);
        check("clip stays when translated", g.getClipX(), 6);
        g.setClip(0, 0, 40, 40);

        // Triangle, arc, round rect leave pixels where expected
        g.setColor(0xFF00FF);
        g.fillTriangle(30, 0, 39, 0, 30, 9);
        check("triangle", px(img, 32, 2), 0xFFFF00FF);
        check("triangle outside", px(img, 38, 8), 0xFFFFFFFF);
        Image c = Image.createImage(21, 21);
        Graphics cg = c.getGraphics();
        cg.setColor(0);
        cg.fillArc(0, 0, 21, 21, 0, 360);
        check("fillArc centre", px(c, 10, 10), 0xFF000000);
        check("fillArc corner", px(c, 0, 0), 0xFFFFFFFF);
        Image quarter = Image.createImage(21, 21);
        cg = quarter.getGraphics();
        cg.setColor(0);
        cg.fillArc(0, 0, 21, 21, 0, 90);
        check("quarter pie in quadrant", px(quarter, 16, 4), 0xFF000000);
        check("quarter pie outside", px(quarter, 4, 16), 0xFFFFFFFF);
        Image rr = Image.createImage(20, 20);
        cg = rr.getGraphics();
        cg.setColor(0);
        cg.fillRoundRect(0, 0, 20, 20, 10, 10);
        check("round corner cut", px(rr, 0, 0), 0xFFFFFFFF);
        check("round middle filled", px(rr, 10, 0), 0xFF000000);

        // Stroke and colour
        g.setStrokeStyle(Graphics.DOTTED);
        check("stroke", g.getStrokeStyle(), Graphics.DOTTED);
        g.setStrokeStyle(Graphics.SOLID);
        g.setColor(10, 20, 30);
        check("colour parts", g.getRedComponent() * 10000 + g.getGreenComponent() * 100 + g.getBlueComponent(), 102030);
        g.setGrayScale(128);
        check("gray", g.getBlueComponent(), 128);

        // Blit with alpha and anchors
        int[] rgb = {0x80000000};
        Image dot = Image.createRGBImage(rgb, 1, 1, true);
        Image white = Image.createImage(4, 4);
        Graphics wg = white.getGraphics();
        wg.drawImage(dot, 1, 1, Graphics.TOP | Graphics.LEFT);
        int blended = px(white, 1, 1) & 0xFF;
        check("alpha blend", blended >= 126 && blended <= 129);

        Image target = Image.createImage(9, 9);
        Graphics tg = target.getGraphics();
        Image blob = Image.createRGBImage(new int[]{0xFF00FF00, 0xFF00FF00, 0xFF00FF00, 0xFF00FF00}, 2, 2, false);
        tg.drawImage(blob, 4, 4, Graphics.HCENTER | Graphics.VCENTER);
        check("centre anchor", px(target, 3, 3), 0xFF00FF00);
        check("centre anchor extent", px(target, 5, 5), 0xFFFFFFFF);
        tg = target.getGraphics();
        tg.drawImage(blob, 9, 9, Graphics.BOTTOM | Graphics.RIGHT);
        check("bottom right anchor", px(target, 8, 8), 0xFF00FF00);

        // drawRGB clipped, copyArea overlapping
        Image dst = Image.createImage(6, 6);
        Graphics dg = dst.getGraphics();
        dg.setClip(0, 0, 2, 2);
        dg.drawRGB(new int[]{0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF, 0xFFABCDEF}, 0, 3, 0, 0, 3, 3, false);
        check("drawRGB clip", px(dst, 1, 1), 0xFFABCDEF);
        check("drawRGB excluded", px(dst, 2, 2), 0xFFFFFFFF);
        dg = dst.getGraphics();
        dg.copyArea(0, 0, 2, 2, 1, 1, Graphics.TOP | Graphics.LEFT);
        check("copyArea", px(dst, 2, 2), 0xFFABCDEF);

        // A Graphics starts with default state on every call
        Graphics fresh = img.getGraphics();
        check("new graphics colour", fresh.getColor(), 0);
    }

    private void testTransforms() {
        // 3x2 image: top-left red, top-right green, bottom-left blue, others white
        int r = 0xFFFF0000, n = 0xFF00FF00, b = 0xFF0000FF, w = 0xFFFFFFFF;
        Image src = Image.createRGBImage(new int[]{r, w, n, b, w, w}, 3, 2, false);
        int[][] expect = {
            // transform, width, height, x of red, y of red
            {Sprite.TRANS_NONE, 3, 2, 0, 0},
            {Sprite.TRANS_MIRROR, 3, 2, 2, 0},
            {Sprite.TRANS_MIRROR_ROT180, 3, 2, 0, 1},
            {Sprite.TRANS_ROT180, 3, 2, 2, 1},
            {Sprite.TRANS_ROT90, 2, 3, 1, 0},
            {Sprite.TRANS_ROT270, 2, 3, 0, 2},
            {Sprite.TRANS_MIRROR_ROT90, 2, 3, 1, 2},
            {Sprite.TRANS_MIRROR_ROT270, 2, 3, 0, 0},
        };
        for (int i = 0; i < expect.length; i++) {
            int[] e = expect[i];
            Image canvas = Image.createImage(4, 4);
            Graphics g = canvas.getGraphics();
            g.drawRegion(src, 0, 0, 3, 2, e[0], 0, 0, Graphics.TOP | Graphics.LEFT);
            check("drawRegion transform " + e[0], px(canvas, e[3], e[4]), r);
            Image made = Image.createImage(src, 0, 0, 3, 2, e[0]);
            check("createImage transform size " + e[0], made.getWidth() * 10 + made.getHeight(), e[1] * 10 + e[2]);
            check("createImage transform pixel " + e[0], px(made, e[3], e[4]), r);
        }
    }

    private void testGameApi() {
        Image strip = Image.createImage(8, 4);
        Graphics g = strip.getGraphics();
        g.setColor(0xFF0000);
        g.fillRect(0, 0, 4, 4);
        g.setColor(0x00FF00);
        g.fillRect(4, 0, 4, 4);

        Sprite s = new Sprite(strip, 4, 4);
        check("sprite frames", s.getRawFrameCount(), 2);
        s.setFrame(1);
        Image canvas = Image.createImage(10, 10);
        Graphics cg = canvas.getGraphics();
        s.setPosition(2, 3);
        s.paint(cg);
        check("sprite paint", px(canvas, 3, 4), 0xFF00FF00);
        Sprite other = new Sprite(strip, 4, 4);
        other.setPosition(4, 4);
        check("collision", s.collidesWith(other, false));
        other.setPosition(9, 9);
        check("no collision", !s.collidesWith(other, false));

        TiledLayer tl = new TiledLayer(2, 1, strip, 4, 4);
        tl.setCell(0, 0, 2);
        tl.setCell(1, 0, 1);
        Image t = Image.createImage(8, 4);
        Graphics tg = t.getGraphics();
        tl.paint(tg);
        check("tiled cell 0", px(t, 1, 1), 0xFF00FF00);
        check("tiled cell 1", px(t, 5, 1), 0xFFFF0000);

        LayerManager lm = new LayerManager();
        Sprite top = new Sprite(strip, 4, 4);
        lm.append(top);
        lm.append(tl);
        Image out = Image.createImage(8, 4);
        lm.setViewWindow(0, 0, 8, 4);
        lm.paint(out.getGraphics(), 0, 0);
        check("layer order", px(out, 1, 1), 0xFFFF0000);
    }

    private void testFont() {
        Font f = Font.getDefaultFont();
        check("font height", f.getHeight() > 4);
        check("baseline", f.getBaselinePosition() > 0 && f.getBaselinePosition() <= f.getHeight());
        check("stringWidth adds up", f.stringWidth("ab") >= f.charWidth('a'));
        check("substringWidth", f.substringWidth("xxabxx", 2, 2), f.stringWidth("ab"));
        check("font identity", Font.getFont(Font.FACE_SYSTEM, Font.STYLE_BOLD, Font.SIZE_LARGE).isBold());
        Image img = Image.createImage(100, 40);
        Graphics g = img.getGraphics();
        g.setColor(0);
        g.drawString("M", 2, 2, Graphics.TOP | Graphics.LEFT);
        boolean inked = false;
        int[] data = new int[100 * 40];
        img.getRGB(data, 0, 100, 0, 0, 100, 40);
        for (int i = 0; i < data.length; i++) if ((data[i] & 0xFF) < 128) inked = true;
        check("text draws pixels", inked);
    }

    private void testMedia() {
        try {
            String[] types = Manager.getSupportedContentTypes(null);
            check("content types", types != null && types.length > 0);
            byte[] seq = {-2, 2, -3, 120, 60, 16, 62, 16};   // tone sequence: version, tempo, notes
            Player p = Manager.createPlayer(new ByteArrayInputStream(seq), "audio/x-tone-seq");
            check("player unrealized", p.getState(), Player.UNREALIZED);
            p.realize();
            check("player realized", p.getState(), Player.REALIZED);
            p.prefetch();
            check("player prefetched", p.getState(), Player.PREFETCHED);
            VolumeControl vc = (VolumeControl) p.getControl("VolumeControl");
            if (vc != null) {
                vc.setLevel(50);
                check("volume", vc.getLevel(), 50);
            }
            p.close();
            check("player closed", p.getState(), Player.CLOSED);
        } catch (Exception e) {
            check("media " + e, false);
        }
    }

    // ------------------------------------------------------------
    // Network, over the loopback interface
    // ------------------------------------------------------------

    private void testTcp() {
        try {
            final ServerSocketConnection server = (ServerSocketConnection) Connector.open("socket://:0");
            int port = server.getLocalPort();
            check("server port", port > 0);
            Thread t = new Thread(new Runnable() {
                public void run() {
                    try {
                        StreamConnection c = server.acceptAndOpen();
                        DataInputStream in = c.openDataInputStream();
                        DataOutputStream out = c.openDataOutputStream();
                        int n = in.readInt();
                        byte[] data = new byte[n];
                        in.readFully(data);
                        out.writeInt(n + 1);
                        out.write(data);
                        out.flush();
                        in.close();
                        out.close();
                        c.close();
                    } catch (IOException e) {
                        System.out.println("[TEST] server error " + e);
                    }
                }
            });
            t.start();

            SocketConnection c = (SocketConnection) Connector.open("socket://127.0.0.1:" + port);
            c.setSocketOption(SocketConnection.DELAY, 0);
            check("DELAY option", c.getSocketOption(SocketConnection.DELAY), 0);
            check("remote port", c.getPort(), port);
            DataOutputStream out = c.openDataOutputStream();
            DataInputStream in = c.openDataInputStream();
            byte[] payload = new byte[20000];
            for (int i = 0; i < payload.length; i++) payload[i] = (byte) i;
            out.writeInt(payload.length);
            out.write(payload);
            out.flush();
            check("reply length", in.readInt(), 20001);
            byte[] back = new byte[payload.length];
            in.readFully(back);
            boolean same = true;
            for (int i = 0; i < back.length; i++) if (back[i] != payload[i]) same = false;
            check("bytes unchanged", same);
            check("end of stream", in.read(), -1);
            in.close();
            out.close();
            c.close();
            server.close();
            try {
                in.read();
                check("read after close", false);
            } catch (IOException e) {
                check("read after close", true);
            }
        } catch (Exception e) {
            check("tcp " + e, false);
            e.printStackTrace();
        }
        try {
            Connector.open("socket://127.0.0.1:1");
            check("refused connection", false);
        } catch (IOException e) {
            check("refused connection", true);
        }
    }

    private void testUdp() {
        try {
            UDPDatagramConnection server = (UDPDatagramConnection) Connector.open("datagram://:47331");
            UDPDatagramConnection client = (UDPDatagramConnection) Connector.open("datagram://127.0.0.1:47331");
            Datagram out = client.newDatagram(8);
            out.writeInt(0xCAFE);
            out.writeInt(99);
            client.send(out);
            Datagram in = server.newDatagram(32);
            server.receive(in);
            check("udp length", in.getLength(), 8);
            check("udp value", in.readInt(), 0xCAFE);
            check("udp second value", in.readInt(), 99);
            check("udp sender", in.getAddress() != null);
            client.close();
            server.close();
        } catch (Exception e) {
            check("udp " + e, false);
            e.printStackTrace();
        }
    }

    private void testHttp() {
        try {
            final ServerSocketConnection server = (ServerSocketConnection) Connector.open("socket://:0");
            int port = server.getLocalPort();
            Thread t = new Thread(new Runnable() {
                public void run() {
                    try {
                        StreamConnection c = server.acceptAndOpen();
                        InputStream in = c.openInputStream();
                        StringBuffer head = new StringBuffer();
                        int b, nl = 0;
                        while (nl < 2 && (b = in.read()) != -1) {
                            if (b == '\n') nl++;
                            else if (b != '\r') nl = 0;
                            head.append((char) b);
                        }
                        OutputStream out = c.openOutputStream();
                        byte[] body = "hello-http".getBytes();
                        String h = "HTTP/1.1 200 OK\r\nContent-Length: " + body.length + "\r\nX-Test: yes\r\nConnection: close\r\n\r\n";
                        out.write(h.getBytes());
                        out.write(body);
                        out.flush();
                        out.close();
                        in.close();
                        c.close();
                    } catch (IOException e) {
                        System.out.println("[TEST] http server error " + e);
                    }
                }
            });
            t.start();
            HttpConnection http = (HttpConnection) Connector.open("http://127.0.0.1:" + port + "/x");
            check("http status", http.getResponseCode(), 200);
            check("http header", "yes".equals(http.getHeaderField("X-Test")));
            InputStream in = http.openInputStream();
            byte[] buf = new byte[32];
            int n, total = 0;
            while ((n = in.read(buf, total, buf.length - total)) > 0) total += n;
            check("http body", new String(buf, 0, total).equals("hello-http"));
            in.close();
            http.close();
            server.close();
        } catch (Exception e) {
            check("http " + e, false);
            e.printStackTrace();
        }
    }

    // ------------------------------------------------------------
    // Event model
    // ------------------------------------------------------------

    private final class EventCanvas extends GameCanvas {
        volatile Thread paintThread, keyThread;
        volatile int shownCount, paints, lastKey, sizeW;
        volatile boolean shownBeforePaint;

        EventCanvas() { super(false); }

        volatile boolean platformCalledGameMethod;

        // Games often have methods with these names; the platform must never call them
        void show() { platformCalledGameMethod = true; }
        void hide() { platformCalledGameMethod = true; }
        void refresh() { platformCalledGameMethod = true; }

        protected void showNotify() { shownCount++; }
        protected void sizeChanged(int w, int h) { sizeW = w; }

        public void paint(Graphics g) {
            if (paintThread == null) { paintThread = Thread.currentThread(); shownBeforePaint = shownCount > 0; }
            paints++;
            g.setColor(0x202040);
            g.fillRect(0, 0, getWidth(), getHeight());
        }

        protected void keyPressed(int code) {
            lastKey = code;
            keyThread = Thread.currentThread();
        }
    }

    private void testEvents() {
        final EventCanvas c = new EventCanvas();
        check("size before show", c.getWidth() * 1000 + c.getHeight(), Display.getScreenWidth() * 1000 + Display.getScreenHeight());
        display.setCurrent(c);
        waitFor(new Condition() { public boolean met() { return c.shownCount > 0 && c.paints > 0; } });
        check("showNotify before first paint", c.shownBeforePaint);
        check("sizeChanged called", c.sizeW, c.getWidth());
        check("isShown", c.isShown());
        check("game methods named like platform ones are left alone", !c.platformCalledGameMethod);
        check("paint on event thread", c.paintThread != null && c.paintThread != Thread.currentThread());

        final Thread[] serial = new Thread[1];
        display.callSerially(new Runnable() { public void run() { serial[0] = Thread.currentThread(); } });
        waitFor(new Condition() { public boolean met() { return serial[0] != null; } });
        check("callSerially on event thread", serial[0] == c.paintThread);

        int before = c.paints;
        c.repaint();
        c.serviceRepaints();
        check("serviceRepaints paints now", c.paints > before);

        check("game actions", c.getGameAction(Canvas.KEY_NUM2), Canvas.UP);
        check("game action arrow", c.getGameAction(Canvas.KEY_LEFT), Canvas.LEFT);
        check("key code of action", c.getKeyCode(Canvas.FIRE), Canvas.KEY_FIRE);
        check("key name", c.getKeyName(Canvas.KEY_NUM5).equals("5"));
        check("key states start empty", c.getKeyStates(), 0);
    }

    private interface Condition { boolean met(); }

    private void waitFor(Condition c) {
        long until = System.currentTimeMillis() + 3000;
        while (!c.met() && System.currentTimeMillis() < until) {
            try { Thread.sleep(10); } catch (InterruptedException e) { return; }
        }
    }

    private void testScreens() {
        final boolean[] command = new boolean[1];
        Form form = new Form("Form");
        TextField tf = new TextField("Ten", "abc", 10, TextField.ANY);
        check("textfield", tf.getString().equals("abc"));
        tf.insert("X", 1);
        check("textfield insert", tf.getString().equals("aXbc"));
        tf.delete(0, 1);
        check("textfield delete", tf.getString().equals("Xbc"));
        try {
            new TextField("x", "toolongtext", 3, TextField.ANY);
            check("textfield limit", false);
        } catch (IllegalArgumentException e) {
            check("textfield limit", true);
        }
        ChoiceGroup group = new ChoiceGroup("Chon", Choice.MULTIPLE, new String[]{"a", "b"}, null);
        group.setSelectedIndex(1, true);
        check("choice", group.isSelected(1) && !group.isSelected(0));
        ChoiceGroup one = new ChoiceGroup("Mot", Choice.EXCLUSIVE, new String[]{"a", "b"}, null);
        check("exclusive default", one.getSelectedIndex(), 0);
        one.setSelectedIndex(1, true);
        check("exclusive moves", one.getSelectedIndex(), 1);
        Gauge gauge = new Gauge("Tai", false, 10, 3);
        gauge.setValue(20);
        check("gauge clamps", gauge.getValue(), 10);
        form.append(tf);
        form.append(group);
        form.append(one);
        form.append(gauge);
        form.append(new StringItem("Nhan", "Noi dung"));
        form.append(new Spacer(10, 4));
        form.append(new DateField("Ngay", DateField.DATE));
        form.append(Image.createImage(8, 8));
        form.addCommand(new Command("OK", Command.OK, 1));
        form.setCommandListener(new CommandListener() {
            public void commandAction(Command c, Displayable d) { command[0] = true; }
        });
        check("form size", form.size(), 8);
        form.delete(7);
        check("form delete", form.size(), 7);
        display.setCurrent(form);
        sleep(100);
        check("current is form", display.getCurrent() == form);

        List list = new List("List", List.IMPLICIT, new String[]{"one", "two"}, null);
        check("list", list.size(), 2);
        check("list selected", list.getSelectedIndex(), 0);
        list.append("three", null);
        list.delete(0);
        check("list edit", list.getString(0).equals("two"));
        display.setCurrent(list);
        sleep(100);

        TextBox box = new TextBox("Box", "nhap", 20, TextField.ANY);
        box.insert("!", 4);
        check("textbox", box.getString().equals("nhap!"));
        check("textbox size", box.size(), 5);
        display.setCurrent(box);
        sleep(100);

        Alert alert = new Alert("Bao", "Xin chao", null, AlertType.INFO);
        alert.setTimeout(Alert.FOREVER);
        check("alert timeout", alert.getTimeout(), Alert.FOREVER);
        display.setCurrent(alert, form);
        sleep(100);
        check("current is alert", display.getCurrent() == alert);
        display.setCurrent(form);
        sleep(50);
    }

    private void sleep(int ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { }
    }

    private String hex(byte[] b, int n) {
        StringBuffer out = new StringBuffer();
        for (int i = 0; i < n; i++) {
            int v = b[i] & 0xFF;
            if (v < 16) out.append('0');
            out.append(Integer.toHexString(v));
        }
        return out.toString();
    }

    private void testDigest() {
        try {
            byte[] data = "abc".getBytes("UTF-8");
            byte[] out = new byte[20];
            java.security.MessageDigest md5 = java.security.MessageDigest.getInstance("MD5");
            md5.update(data, 0, data.length);
            int n = md5.digest(out, 0, 16);
            check("md5", n == 16 && hex(out, 16).equals("900150983cd24fb0d6963f7d28e17f72"));
            java.security.MessageDigest sha = java.security.MessageDigest.getInstance("SHA-1");
            sha.update(data, 0, data.length);
            n = sha.digest(out, 0, 20);
            check("sha1", n == 20 && hex(out, 20).equals("a9993e364706816aba3e25717850c26c9cd0d89d"));
        } catch (Exception e) {
            check("digest " + e, false);
        }
    }

    /** Reaches the Internet, so it only reports; it never fails the run. */
    private void probeHttps() {
        try {
            HttpConnection http = (HttpConnection) Connector.open("https://example.com/");
            System.out.println("[TEST] INFO https status " + http.getResponseCode());
            http.close();
        } catch (Throwable t) {
            System.out.println("[TEST] INFO https unavailable: " + t);
        }
    }

    private void testProperties() {
        check("app property", "SelfValue".equals(getAppProperty("SelfTest-Key")));
        check("microedition.platform", System.getProperty("microedition.platform") != null);
        check("configuration", "CLDC-1.1".equals(System.getProperty("microedition.configuration")));
        check("profile", "MIDP-2.0".equals(System.getProperty("microedition.profiles")));
        check("encoding", System.getProperty("microedition.encoding") != null);
        check("display color", display.isColor());
        check("alpha levels", display.numAlphaLevels() > 2);
        check("system colour", display.getColor(Display.COLOR_BACKGROUND) == 0xFFFFFF);
        check("resume request safe", true);
        resumeRequest();
        check("permission", checkPermission("javax.microedition.io.Connector.socket"), 1);
    }
}
