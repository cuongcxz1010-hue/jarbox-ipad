package javax.microedition.lcdui;

import javax.microedition.lcdui.event.CommandActionEvent;

public class List extends Screen implements Choice {
    public static final Command SELECT_COMMAND = new Command("", Command.SCREEN, 0);

    private final int listType;
    private final ChoiceModel model;
    private Command selectCommand = SELECT_COMMAND;

    public List(String title, int listType) {
        this(title, listType, new String[0], null);
    }

    public List(String title, int listType, String[] stringElements, Image[] imageElements) {
        if (listType != IMPLICIT && listType != EXCLUSIVE && listType != MULTIPLE) throw new IllegalArgumentException();
        if (stringElements == null) throw new NullPointerException();
        setTitle(title);
        this.listType = listType;
        model = new ChoiceModel(listType);
        for (int i = 0; i < stringElements.length; i++)
            model.append(stringElements[i], imageElements != null && i < imageElements.length ? imageElements[i] : null);
    }

    public int append(String s, Image img) { int r = model.append(s, img); contentChanged(); return r; }
    public void delete(int i) { model.delete(i); contentChanged(); }
    public void deleteAll() { model.deleteAll(); contentChanged(); }
    public int getSelectedIndex() { return model.getSelectedIndex(); }
    public String getString(int i) { return model.getString(i); }
    public Image getImage(int i) { return model.getImage(i); }
    public void insert(int i, String s, Image img) { model.insert(i, s, img); contentChanged(); }
    public boolean isSelected(int i) { return model.isSelected(i); }
    public void set(int i, String s, Image img) { model.set(i, s, img); contentChanged(); }
    public void setSelectedIndex(int i, boolean s) { model.setSelected(i, s); contentChanged(); }
    public int size() { return model.size(); }
    public int getSelectedFlags(boolean[] a) { return model.getSelectedFlags(a); }
    public void setSelectedFlags(boolean[] a) { model.setSelectedFlags(a); contentChanged(); }
    public int getFitPolicy() { return model.getFitPolicy(); }
    public void setFitPolicy(int p) { model.setFitPolicy(p); }
    public Font getFont(int i) { return model.getFont(i); }
    public void setFont(int i, Font f) { model.setFont(i, f); }

    public void setSelectCommand(Command cmd) {
        if (listType != IMPLICIT) return;
        if (cmd != null && cmd != SELECT_COMMAND) addCommand(cmd);
        selectCommand = cmd;
    }

    @Override
    void writeContent(ScreenWriter out) {
        out.field("kind", "list");
        out.field("mode", listType);
        model.write(out);
    }

    @Override
    void onListSelect(int index) {
        if (index < 0 || index >= model.size()) return;
        if (listType == MULTIPLE) {
            model.setSelected(index, !model.isSelected(index));
            return;
        }
        model.setSelected(index, true);
        if (listType == IMPLICIT && selectCommand != null && getCommandListener() != null) {
            Display.postEvent(CommandActionEvent.getInstance(getCommandListener(), selectCommand, this));
        }
    }
}
