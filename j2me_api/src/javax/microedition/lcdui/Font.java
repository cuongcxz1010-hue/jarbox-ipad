package javax.microedition.lcdui;

/**
 * J2ME Font with real metrics from Core Text.
 *
 * One shared instance per (face, style, size). Height and ascent are read
 * once; character widths are measured once and cached (1/64 px), so
 * charWidth / stringWidth are cheap even when a game lays out text every
 * frame. Drawing uses the same font without kerning or ligatures, so the
 * measured width matches what is drawn.
 */
public class Font {
    public static final int FACE_SYSTEM = 0;
    public static final int FACE_MONOSPACE = 32;
    public static final int FACE_PROPORTIONAL = 64;

    public static final int STYLE_PLAIN = 0;
    public static final int STYLE_BOLD = 1;
    public static final int STYLE_ITALIC = 2;
    public static final int STYLE_UNDERLINED = 4;

    public static final int SIZE_SMALL = 8;
    public static final int SIZE_MEDIUM = 0;
    public static final int SIZE_LARGE = 16;

    public static final int FONT_STATIC_TEXT = 0;
    public static final int FONT_INPUT_TEXT = 1;

    /** Characters below this code point have their width cached. */
    private static final int CACHE_LIMIT = 0x2000;

    private static final Font[] fonts = new Font[3 * 8 * 3];

    private final int face, style, size;
    private final int height, ascent;
    private short[] widths64;       // lazily filled; 0 = not measured yet (stored as width + 1)

    private Font(int face, int style, int size) {
        this.face = face;
        this.style = style;
        this.size = size;
        int h = 16, a = 13;
        try {
            h = NativeBridge.fontHeight(face, style, size);
            a = NativeBridge.fontAscent(face, style, size);
        } catch (Throwable t) {
            // keep defaults
        }
        this.height = h;
        this.ascent = a;
    }

    private static int faceIndex(int face) {
        return face == FACE_MONOSPACE ? 1 : (face == FACE_PROPORTIONAL ? 2 : 0);
    }

    private static int sizeIndex(int size) {
        return size == SIZE_SMALL ? 0 : (size == SIZE_LARGE ? 2 : 1);
    }

    public static Font getFont(int face, int style, int size) {
        // Lenient like most phones: unknown values fall back instead of throwing
        if (face != FACE_SYSTEM && face != FACE_MONOSPACE && face != FACE_PROPORTIONAL) face = FACE_SYSTEM;
        style &= 7;
        if (size != SIZE_SMALL && size != SIZE_MEDIUM && size != SIZE_LARGE) size = SIZE_MEDIUM;
        int key = (faceIndex(face) * 8 + style) * 3 + sizeIndex(size);
        synchronized (fonts) {
            Font f = fonts[key];
            if (f == null) {
                f = new Font(face, style, size);
                fonts[key] = f;
            }
            return f;
        }
    }

    public static Font getFont(int fontSpecifier) {
        if (fontSpecifier != FONT_STATIC_TEXT && fontSpecifier != FONT_INPUT_TEXT)
            throw new IllegalArgumentException();
        return getDefaultFont();
    }

    public static Font getDefaultFont() {
        return getFont(FACE_SYSTEM, STYLE_PLAIN, SIZE_MEDIUM);
    }

    public int getFace() { return face; }
    public int getStyle() { return style; }
    public int getSize() { return size; }

    public boolean isPlain() { return style == STYLE_PLAIN; }
    public boolean isBold() { return (style & STYLE_BOLD) != 0; }
    public boolean isItalic() { return (style & STYLE_ITALIC) != 0; }
    public boolean isUnderlined() { return (style & STYLE_UNDERLINED) != 0; }

    public int getHeight() { return height; }

    public int getBaselinePosition() { return ascent; }

    /** Width of one character in 1/64 pixel (cached). */
    private int width64(char ch) {
        if (ch >= CACHE_LIMIT) return NativeBridge.charWidth64(face, style, size, ch);
        short[] w = widths64;
        if (w == null) {
            w = new short[CACHE_LIMIT];
            widths64 = w;
        }
        int v = w[ch];
        if (v == 0) {
            int measured = NativeBridge.charWidth64(face, style, size, ch);
            if (measured < 0) measured = 0;
            if (measured > 32000) measured = 32000;
            v = measured + 1;
            w[ch] = (short) v;
        }
        return v - 1;
    }

    public int charWidth(char ch) {
        return (width64(ch) + 32) >> 6;
    }

    public int charsWidth(char[] ch, int offset, int length) {
        if (ch == null) throw new NullPointerException();
        if (offset < 0 || length < 0 || offset + length > ch.length) throw new ArrayIndexOutOfBoundsException();
        int sum = 0;
        for (int i = offset, end = offset + length; i < end; i++) sum += width64(ch[i]);
        return (sum + 32) >> 6;
    }

    public int stringWidth(String str) {
        if (str == null) throw new NullPointerException();
        int sum = 0;
        for (int i = 0, n = str.length(); i < n; i++) sum += width64(str.charAt(i));
        return (sum + 32) >> 6;
    }

    public int substringWidth(String str, int offset, int len) {
        if (str == null) throw new NullPointerException();
        if (offset < 0 || len < 0 || offset + len > str.length()) throw new StringIndexOutOfBoundsException();
        int sum = 0;
        for (int i = offset, end = offset + len; i < end; i++) sum += width64(str.charAt(i));
        return (sum + 32) >> 6;
    }

    /**
     * Apply this font to a native context. Called by Graphics when the font changes.
     */
    void applyToContext(long ctx) {
        NativeBridge.setFont(ctx, face, style, size);
    }

    /**
     * Measure string width using the given native context.
     */
    int stringWidth(long ctx, String str) {
        return stringWidth(str);
    }
}
