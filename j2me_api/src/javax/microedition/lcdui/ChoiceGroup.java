package javax.microedition.lcdui;

public class ChoiceGroup extends Item implements Choice {
    private final int choiceType;
    private final ChoiceModel model;

    public ChoiceGroup(String label, int choiceType) {
        this(label, choiceType, new String[0], null);
    }

    public ChoiceGroup(String label, int choiceType, String[] stringElements, Image[] imageElements) {
        if (choiceType != EXCLUSIVE && choiceType != MULTIPLE && choiceType != POPUP) throw new IllegalArgumentException();
        if (stringElements == null) throw new NullPointerException();
        setLabel(label);
        this.choiceType = choiceType;
        model = new ChoiceModel(choiceType);
        for (int i = 0; i < stringElements.length; i++)
            model.append(stringElements[i], imageElements != null && i < imageElements.length ? imageElements[i] : null);
    }

    public int append(String s, Image img) { int r = model.append(s, img); midpChanged(); return r; }
    public void delete(int i) { model.delete(i); midpChanged(); }
    public void deleteAll() { model.deleteAll(); midpChanged(); }
    public int getSelectedIndex() { return model.getSelectedIndex(); }
    public String getString(int i) { return model.getString(i); }
    public Image getImage(int i) { return model.getImage(i); }
    public void insert(int i, String s, Image img) { model.insert(i, s, img); midpChanged(); }
    public boolean isSelected(int i) { return model.isSelected(i); }
    public void set(int i, String s, Image img) { model.set(i, s, img); midpChanged(); }
    public void setSelectedIndex(int i, boolean s) { model.setSelected(i, s); midpChanged(); }
    public int size() { return model.size(); }
    public int getSelectedFlags(boolean[] a) { return model.getSelectedFlags(a); }
    public void setSelectedFlags(boolean[] a) { model.setSelectedFlags(a); midpChanged(); }
    public int getFitPolicy() { return model.getFitPolicy(); }
    public void setFitPolicy(int p) { model.setFitPolicy(p); }
    public Font getFont(int i) { return model.getFont(i); }
    public void setFont(int i, Font f) { model.setFont(i, f); }

    @Override
    void midpWrite(ScreenWriter out) {
        out.field("kind", "choice");
        out.field("mode", choiceType);
        model.write(out);
    }

    @Override
    boolean midpNativeValue(String v) { return model.applyFlags(v); }
}
