package javax.microedition.lcdui;

public class ImageItem extends Item {
    public static final int LAYOUT_DEFAULT = 0;
    public static final int LAYOUT_LEFT = 1;
    public static final int LAYOUT_RIGHT = 2;
    public static final int LAYOUT_CENTER = 3;
    public static final int LAYOUT_NEWLINE_BEFORE = 0x100;
    public static final int LAYOUT_NEWLINE_AFTER = 0x200;

    private Image image;
    private String altText;
    private final int appearanceMode;

    public ImageItem(String label, Image img, int layout, String altText) {
        this(label, img, layout, altText, PLAIN);
    }

    public ImageItem(String label, Image img, int layout, String altText, int appearanceMode) {
        setLabel(label);
        setLayout(layout);
        this.image = img;
        this.altText = altText;
        this.appearanceMode = appearanceMode;
    }

    public Image getImage() { return image; }
    public void setImage(Image img) { image = img; changed(); }
    public String getAltText() { return altText; }
    public void setAltText(String text) { altText = text; changed(); }
    public int getAppearanceMode() { return appearanceMode; }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "image");
        out.field("alt", altText);
        out.image("image", image);
        out.field("appearance", appearanceMode);
    }
}
