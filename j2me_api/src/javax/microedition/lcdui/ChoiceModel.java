package javax.microedition.lcdui;

import java.util.ArrayList;

/** The list of options shared by List and ChoiceGroup. */
final class ChoiceModel {
    private final ArrayList<String> strings = new ArrayList<String>();
    private final ArrayList<Image> images = new ArrayList<Image>();
    private final ArrayList<Font> fonts = new ArrayList<Font>();
    private boolean[] selected = new boolean[8];
    private final int type;
    private int fitPolicy = Choice.TEXT_WRAP_DEFAULT;

    ChoiceModel(int type) { this.type = type; }

    private boolean singleSelection() { return type != Choice.MULTIPLE; }

    private void checkIndex(int i) {
        if (i < 0 || i >= strings.size()) throw new IndexOutOfBoundsException();
    }

    private void ensure(int n) {
        if (n > selected.length) {
            boolean[] grown = new boolean[n * 2];
            System.arraycopy(selected, 0, grown, 0, selected.length);
            selected = grown;
        }
    }

    int size() { return strings.size(); }

    int append(String s, Image img) {
        if (s == null) throw new NullPointerException();
        int i = strings.size();
        insert(i, s, img);
        return i;
    }

    void insert(int i, String s, Image img) {
        if (i < 0 || i > strings.size()) throw new IndexOutOfBoundsException();
        if (s == null) throw new NullPointerException();
        boolean wasEmpty = strings.isEmpty();
        strings.add(i, s);
        images.add(i, img);
        fonts.add(i, null);
        ensure(strings.size());
        System.arraycopy(selected, i, selected, i + 1, strings.size() - 1 - i);
        selected[i] = wasEmpty && singleSelection();
    }

    void delete(int i) {
        checkIndex(i);
        boolean wasSelected = selected[i];
        strings.remove(i);
        images.remove(i);
        fonts.remove(i);
        System.arraycopy(selected, i + 1, selected, i, strings.size() - i);
        selected[strings.size()] = false;
        if (wasSelected && singleSelection() && !strings.isEmpty()) {
            selected[i < strings.size() ? i : strings.size() - 1] = true;
        }
    }

    void deleteAll() {
        strings.clear();
        images.clear();
        fonts.clear();
        selected = new boolean[8];
    }

    void set(int i, String s, Image img) {
        checkIndex(i);
        if (s == null) throw new NullPointerException();
        strings.set(i, s);
        images.set(i, img);
    }

    String getString(int i) { checkIndex(i); return strings.get(i); }
    Image getImage(int i) { checkIndex(i); return images.get(i); }

    boolean isSelected(int i) { checkIndex(i); return selected[i]; }

    int getSelectedIndex() {
        if (!singleSelection()) return -1;
        for (int i = 0; i < strings.size(); i++) if (selected[i]) return i;
        return -1;
    }

    void setSelected(int i, boolean sel) {
        checkIndex(i);
        if (singleSelection()) {
            if (!sel) return;
            for (int k = 0; k < strings.size(); k++) selected[k] = false;
            selected[i] = true;
        } else {
            selected[i] = sel;
        }
    }

    int getSelectedFlags(boolean[] out) {
        if (out == null) throw new NullPointerException();
        if (out.length < strings.size()) throw new IllegalArgumentException();
        int count = 0;
        for (int i = 0; i < out.length; i++) {
            out[i] = i < strings.size() && selected[i];
            if (out[i]) count++;
        }
        return count;
    }

    void setSelectedFlags(boolean[] in) {
        if (in == null) throw new NullPointerException();
        if (in.length < strings.size()) throw new IllegalArgumentException();
        if (singleSelection()) {
            int first = -1;
            for (int i = 0; i < strings.size() && first < 0; i++) if (in[i]) first = i;
            if (first < 0 && !strings.isEmpty()) first = 0;
            for (int i = 0; i < strings.size(); i++) selected[i] = i == first;
        } else {
            for (int i = 0; i < strings.size(); i++) selected[i] = in[i];
        }
    }

    int getFitPolicy() { return fitPolicy; }
    void setFitPolicy(int p) { fitPolicy = p; }

    Font getFont(int i) {
        checkIndex(i);
        Font f = fonts.get(i);
        return f != null ? f : Font.getDefaultFont();
    }

    void setFont(int i, Font f) { checkIndex(i); fonts.set(i, f); }

    void write(ScreenWriter out) {
        out.beginArray("options");
        for (int i = 0; i < strings.size(); i++) {
            out.beginObject();
            out.field("text", strings.get(i));
            out.image("image", images.get(i));
            out.field("selected", selected[i]);
            out.endObject();
        }
        out.endArray();
    }

    /** Native value: one '0' or '1' per option. */
    boolean applyFlags(String v) {
        boolean changed = false;
        for (int i = 0; i < strings.size() && i < v.length(); i++) {
            boolean sel = v.charAt(i) == '1';
            if (selected[i] != sel) { selected[i] = sel; changed = true; }
        }
        return changed;
    }
}
