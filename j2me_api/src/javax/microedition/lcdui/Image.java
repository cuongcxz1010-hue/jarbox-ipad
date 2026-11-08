package javax.microedition.lcdui;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * J2ME Image — wraps a native CGImage/CGBitmapContext handle.
 * Analogous to J2ME-Loader's Image wrapping android.graphics.Bitmap.
 */
public class Image {
    public long nativeHandle; // RenderImage pointer
    private int width, height;
    private boolean mutable;

    public Image(long nativeHandle, int width, int height, boolean mutable) {
        this.nativeHandle = nativeHandle;
        this.width = width;
        this.height = height;
        this.mutable = mutable;
    }

    public static Image createImage(int width, int height) {
        if (width <= 0 || height <= 0) throw new IllegalArgumentException();
        long handle = NativeBridge.createMutableImage(width, height);
        if (handle == 0) throw new OutOfMemoryError("createImage " + width + "x" + height);
        return new Image(handle, width, height, true);
    }

    /** Mutable image of one ARGB colour, transparency kept (Nokia, Siemens). */
    public static Image createImage(int width, int height, int argb) {
        if (width <= 0 || height <= 0) throw new IllegalArgumentException();
        long handle = NativeBridge.createFilledImage(width, height, argb);
        if (handle == 0) throw new OutOfMemoryError("createImage " + width + "x" + height);
        return new Image(handle, width, height, true);
    }

    public static Image createImage(String name) throws IOException {
        if (name == null) throw new NullPointerException();
        InputStream is = javax.microedition.util.GameResources.open(name);
        if (is == null) throw new IOException("Image resource not found: " + name);
        return createImage(is);
    }

    public static Image createImage(InputStream stream) throws IOException {
        byte[] data = readAllBytes(stream);
        return createImage(data, 0, data.length);
    }

    public static Image createImage(byte[] imageData, int imageOffset, int imageLength) {
        long handle = NativeBridge.createImageFromData(imageData, imageOffset, imageLength);
        if (handle == 0) {
            throw new IllegalArgumentException("Failed to decode image data");
        }
        int w = NativeBridge.getImageWidth(handle);
        int h = NativeBridge.getImageHeight(handle);
        return new Image(handle, w, h, false);
    }

    public static Image createImage(Image source, int x, int y, int width, int height, int transform) {
        if (source == null) throw new NullPointerException();
        if (width <= 0 || height <= 0) throw new IllegalArgumentException();
        if (x < 0 || y < 0 || x + width > source.width || y + height > source.height) throw new IllegalArgumentException();
        if (transform < 0 || transform > 7) throw new IllegalArgumentException();
        if (!source.mutable && transform == 0 && x == 0 && y == 0 && width == source.width && height == source.height) return source;
        long handle = NativeBridge.createImageFromRegion(source.nativeHandle, x, y, width, height, transform);
        if (handle == 0) throw new OutOfMemoryError();
        return new Image(handle, NativeBridge.getImageWidth(handle), NativeBridge.getImageHeight(handle), false);
    }

    public static Image createImage(Image source) {
        if (source == null) throw new NullPointerException();
        if (!source.mutable) return source;
        return createImage(source, 0, 0, source.width, source.height, 0);
    }

    public static Image createRGBImage(int[] rgb, int width, int height, boolean processAlpha) {
        if (rgb == null) throw new NullPointerException();
        if (width <= 0 || height <= 0) throw new IllegalArgumentException();
        if ((long) width * height > rgb.length) throw new ArrayIndexOutOfBoundsException();
        long handle = NativeBridge.createImageFromRGB(rgb, width, height, processAlpha);
        if (handle == 0) throw new OutOfMemoryError();
        return new Image(handle, width, height, false);
    }

    /** A new Graphics with default state on every call, as MIDP specifies. */
    public Graphics getGraphics() {
        if (!mutable) throw new IllegalStateException("Image is not mutable");
        long ctx = NativeBridge.getImageContext(nativeHandle);
        Graphics g = new Graphics(ctx, width, height);
        g.ownsContext = true;
        return g;
    }

    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public boolean isMutable() { return mutable; }

    public void getRGB(int[] rgbData, int offset, int scanlength,
                       int x, int y, int w, int h) {
        if (rgbData == null) throw new NullPointerException();
        if (x < 0 || y < 0 || x + w > width || y + h > height) throw new IllegalArgumentException();
        NativeBridge.getImageRGB(nativeHandle, rgbData, offset, scanlength, x, y, w, h);
    }

    private static byte[] readAllBytes(InputStream is) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream(4096);
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) > 0) {
            bos.write(buf, 0, n);
        }
        is.close();
        return bos.toByteArray();
    }

    protected void finalize() throws Throwable {
        // Don't destroy cachedGraphics.nativeContext here — the Graphics
        // object may still be in use on another thread's stack.
        // Graphics.finalize() will release its own RenderContext (ownsContext=true).
        if (nativeHandle != 0) {
            NativeBridge.destroyImage(nativeHandle);
            nativeHandle = 0;
        }
        super.finalize();
    }
}
