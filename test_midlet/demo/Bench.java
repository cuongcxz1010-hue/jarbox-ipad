import javax.microedition.midlet.MIDlet;

/**
 * Interpreter benchmark: the mix of work that dominates game logic. Prints one
 * score line per section, higher is better, so builds can be compared.
 */
public class Bench extends MIDlet implements Runnable {
    protected void startApp() { new Thread(this, "Bench").start(); }
    protected void pauseApp() { }
    protected void destroyApp(boolean unconditional) { }

    private static final int MS = 1500;

    static final class Actor {
        int x, y, hp;
        Actor next;
        int step(int d) { x += d; y ^= x; hp--; return x + y; }
    }

    interface Rule { int apply(int v); }
    static final class Add implements Rule { public int apply(int v) { return v + 3; } }
    static final class Mul implements Rule { public int apply(int v) { return v * 5; } }

    private interface Work { int run(); }

    private void measure(String name, Work w) {
        long end = System.currentTimeMillis() + MS;
        long rounds = 0;
        int sink = 0;
        while (System.currentTimeMillis() < end) {
            sink += w.run();
            rounds++;
        }
        System.out.println("[BENCH] " + name + " " + (rounds * 1000 / MS) + " (" + sink + ")");
    }

    public void run() {
        measure("arithmetic", new Work() { public int run() {
            int a = 1, b = 7;
            for (int i = 0; i < 2000; i++) { a = (a * 31 + b) ^ (i >> 2); b += a & 15; }
            return a;
        } });
        final int[] table = new int[256];
        measure("arrays", new Work() { public int run() {
            int sum = 0;
            for (int i = 0; i < 2000; i++) { table[i & 255] += i; sum += table[(i * 7) & 255]; }
            return sum;
        } });
        final Actor[] actors = new Actor[32];
        for (int i = 0; i < actors.length; i++) actors[i] = new Actor();
        measure("fields and calls", new Work() { public int run() {
            int sum = 0;
            for (int n = 0; n < 40; n++) for (int i = 0; i < actors.length; i++) sum += actors[i].step(n);
            return sum;
        } });
        final Rule[] rules = {new Add(), new Mul(), new Add()};
        measure("interface calls", new Work() { public int run() {
            int v = 1;
            for (int i = 0; i < 1000; i++) v = rules[i % 3].apply(v);
            return v;
        } });
        measure("allocation", new Work() { public int run() {
            int sum = 0;
            for (int i = 0; i < 200; i++) { byte[] b = new byte[64]; b[0] = 1; sum += b.length; }
            return sum;
        } });
        measure("strings", new Work() { public int run() {
            StringBuffer sb = new StringBuffer();
            for (int i = 0; i < 40; i++) sb.append(i).append('x');
            return sb.toString().indexOf("39");
        } });
        System.out.println("[BENCH] done");
    }
}
