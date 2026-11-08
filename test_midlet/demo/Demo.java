import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Display;
import javax.microedition.lcdui.Font;
import javax.microedition.lcdui.Graphics;
import javax.microedition.lcdui.Image;
import javax.microedition.lcdui.game.GameCanvas;
import javax.microedition.lcdui.game.Sprite;
import javax.microedition.midlet.MIDlet;

/**
 * A small animated scene that exercises what games do every frame: a tile
 * background, moving sprites with transparency, text and key input. It prints
 * the frame rate, so the same scene can be compared between builds.
 */
public class Demo extends MIDlet implements Runnable {
    private DemoCanvas canvas;
    private volatile boolean running = true;

    protected void startApp() {
        canvas = new DemoCanvas();
        Display.getDisplay(this).setCurrent(canvas);
        new Thread(this, "DemoLoop").start();
    }

    protected void pauseApp() { }
    protected void destroyApp(boolean unconditional) { running = false; }

    public void run() {
        long reportAt = System.currentTimeMillis() + 2000;
        int frames = 0;
        while (running) {
            canvas.frame();
            frames++;
            long now = System.currentTimeMillis();
            if (now >= reportAt) {
                canvas.fps = frames / 2;
                System.out.println("[DEMO] fps=" + canvas.fps + " sprites=" + DemoCanvas.COUNT);
                frames = 0;
                reportAt = now + 2000;
            }
            Thread.yield();
        }
    }

    private static final class DemoCanvas extends GameCanvas {
        static final int COUNT = 60;
        final Image tile, sheet;
        final int[] x = new int[COUNT], y = new int[COUNT], dx = new int[COUNT], dy = new int[COUNT];
        final Graphics g;
        int frame, heroX, heroY;
        volatile int fps;

        DemoCanvas() {
            super(false);
            setFullScreenMode(true);
            g = getGraphics();
            int[] t = new int[32 * 32];
            for (int i = 0; i < t.length; i++) {
                int px = i % 32, py = i / 32;
                t[i] = ((px / 8 + py / 8) & 1) == 0 ? 0xFF2F6F4F : 0xFF3A8A5F;
            }
            tile = Image.createRGBImage(t, 32, 32, false);
            int[] s = new int[64 * 16];
            for (int i = 0; i < s.length; i++) {
                int px = i % 64, py = i / 64;
                int cx = px % 16 - 8, cy = py - 8;
                if (cx * cx + cy * cy > 56) s[i] = 0;
                else s[i] = 0xFF000000 | (px < 16 ? 0xE04040 : px < 32 ? 0xE0C040 : px < 48 ? 0x4080F0 : 0xC060E0);
            }
            sheet = Image.createRGBImage(s, 64, 16, true);
            for (int i = 0; i < COUNT; i++) {
                x[i] = (i * 37) % Math.max(1, getWidth());
                y[i] = (i * 53) % Math.max(1, getHeight());
                dx[i] = 1 + (i % 3);
                dy[i] = 1 + ((i + 1) % 2);
            }
            heroX = getWidth() / 2;
            heroY = getHeight() / 2;
        }

        void frame() {
            int w = getWidth(), h = getHeight();
            int scroll = frame % 32;
            for (int ty = -32; ty < h; ty += 32)
                for (int tx = -32; tx < w; tx += 32)
                    g.drawImage(tile, tx + scroll, ty + scroll, Graphics.TOP | Graphics.LEFT);
            for (int i = 0; i < COUNT; i++) {
                x[i] += dx[i];
                y[i] += dy[i];
                if (x[i] < 0 || x[i] > w - 16) dx[i] = -dx[i];
                if (y[i] < 0 || y[i] > h - 16) dy[i] = -dy[i];
                g.drawRegion(sheet, ((frame / 8 + i) % 4) * 16, 0, 16, 16, i % 8, x[i], y[i], Graphics.TOP | Graphics.LEFT);
            }
            int keys = getKeyStates();
            if ((keys & LEFT_PRESSED) != 0) heroX -= 2;
            if ((keys & RIGHT_PRESSED) != 0) heroX += 2;
            if ((keys & UP_PRESSED) != 0) heroY -= 2;
            if ((keys & DOWN_PRESSED) != 0) heroY += 2;
            g.setColor(0xFFFFFF);
            g.fillRoundRect(heroX - 10, heroY - 10, 20, 20, 8, 8);
            g.setColor(0x000000);
            g.fillRect(0, h - 22, w, 22);
            g.setColor(0xFFFF80);
            g.setFont(Font.getFont(Font.FACE_SYSTEM, Font.STYLE_BOLD, Font.SIZE_SMALL));
            g.drawString("Demo " + w + "x" + h + " fps " + fps, 2, h - 20, Graphics.TOP | Graphics.LEFT);
            flushGraphics();
            frame++;
        }

        protected void keyPressed(int code) {
            System.out.println("[DEMO] keyPressed " + code + " action " + getGameAction(code));
        }

        protected void pointerPressed(int px, int py) {
            heroX = px;
            heroY = py;
        }
    }
}
