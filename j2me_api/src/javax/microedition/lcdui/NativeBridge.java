package javax.microedition.lcdui;

/**
 * Native bridge to Core Graphics rendering on iOS.
 * Each method maps to a CGContext operation via miniJVM native methods.
 * Analogous to J2ME-Loader's use of android.graphics.Canvas.
 */
public class NativeBridge {
    // Context
    public static native long createContext(int w, int h);
    public static native void destroyContext(long ctx);
    public static native void flushToScreen(long ctx);

    // Color & State
    public static native void setColor(long ctx, int argb);
    public static native void setClip(long ctx, int x, int y, int w, int h);
    public static native void setStrokeStyle(long ctx, int style);

    // Drawing
    public static native void drawLine(long ctx, int x1, int y1, int x2, int y2);
    public static native void fillRect(long ctx, int x, int y, int w, int h);
    public static native void drawRect(long ctx, int x, int y, int w, int h);
    public static native void fillArc(long ctx, int x, int y, int w, int h, int sa, int aa);
    public static native void drawArc(long ctx, int x, int y, int w, int h, int sa, int aa);
    public static native void fillRoundRect(long ctx, int x, int y, int w, int h, int aw, int ah);
    public static native void drawRoundRect(long ctx, int x, int y, int w, int h, int aw, int ah);
    public static native void fillTriangle(long ctx, int x1, int y1, int x2, int y2, int x3, int y3);

    // Text
    public static native void setFont(long ctx, int face, int style, int size);
    public static native void drawString(long ctx, String str, int x, int y, int anchor);
    public static native int getStringWidth(long ctx, String str);
    public static native int getFontHeight(long ctx);
    public static native int getFontAscent(long ctx);
    /** Font metrics without a context (face, style, size as in javax.microedition.lcdui.Font). */
    public static native int fontHeight(int face, int style, int size);
    public static native int fontAscent(int face, int style, int size);
    /** Advance of one character in 1/64 pixel. */
    public static native int charWidth64(int face, int style, int size, int ch);
    public static native int stringWidthFont(int face, int style, int size, String str);

    // Image
    public static native long createMutableImage(int w, int h);
    public static native long createFilledImage(int w, int h, int argb);
    public static native long createImageFromRGB(int[] rgb, int w, int h, boolean processAlpha);
    public static native long createImageFromRegion(long img, int x, int y, int w, int h, int transform);
    public static native String imagePngBase64(long img);
    public static native long createImageFromData(byte[] data, int offset, int length);
    public static native void destroyImage(long img);
    public static native int getImageWidth(long img);
    public static native int getImageHeight(long img);
    public static native long getImageContext(long img);
    public static native void drawImage(long ctx, long img, int x, int y, int anchor);
    public static native void drawRegion(long ctx, long img, int xSrc, int ySrc,
        int wSrc, int hSrc, int transform, int xDst, int yDst, int anchor);
    public static native void drawRGB(long ctx, int[] rgbData, int offset,
        int scanlength, int x, int y, int w, int h, int processAlpha);
    public static native void getImageRGB(long img, int[] rgbData, int offset,
        int scanlength, int x, int y, int w, int h);
    public static native void getContextRGB(long ctx, int[] rgbData, int offset,
        int scanlength, int x, int y, int w, int h);
    public static native void fillPolygon(long ctx, int[] xPoints, int[] yPoints, int nPoints);
    public static native void drawPolygon(long ctx, int[] xPoints, int[] yPoints, int nPoints);
    public static native void copyArea(long ctx, int xSrc, int ySrc, int w, int h, int xDst, int yDst);

    // Input: blocks up to timeoutMs; {type, x, y, keyCode} or null
    public static native int[] waitInputEvent(int timeoutMs);
    public static native void wakeInput();

    // Lifecycle — check if native side requested MIDlet stop
    public static native boolean isStopRequested();
    public static native void reportFailure(String message);

    // High-level screens: one JSON document per screen (see ScreenWriter)
    public static native void showScreen(String json);
    public static native void showCanvas();
    public static native void setCanvasCommands(String json);
    public static native String takeTextResult(int index);

    // Audio — WAV/MP3 (AVAudioPlayer)
    public static native long audioCreatePlayer(byte[] data);
    public static native void audioStart(long handle);
    public static native void audioStop(long handle);
    public static native void audioClose(long handle);
    public static native void audioSetLoop(long handle, int count);
    public static native void audioSetVolume(long handle, float volume);
    public static native long audioGetDuration(long handle);
    public static native long audioGetTime(long handle);

    // Audio — MIDI (AVMIDIPlayer + gs_instruments.sf2)
    public static native long audioCreateMidiPlayer(byte[] data);
    public static native void audioMidiStart(long handle);
    public static native void audioMidiStop(long handle);
    public static native void audioMidiClose(long handle);

    // Audio — Tone (convenience, uses MIDI internally)
    public static native void audioPlayTone(int note, int duration, int volume);

    // MascotCapsule micro3D — blit GL framebuffer pixels to CGBitmapContext
    public static native void mc3dBlitToGraphics(long ctx, long pixelsAddr, int width, int height);
    // MascotCapsule micro3D — read Canvas CGBitmapContext pixels as RGBA for GL texture upload
    public static native void mc3dReadCanvasPixels(long ctx, long dstAddr, int width, int height);

    // Platform
    public static native void platformRequest(String url);

    // Haptics
    public static native void vibrate(int durationMs);
}
