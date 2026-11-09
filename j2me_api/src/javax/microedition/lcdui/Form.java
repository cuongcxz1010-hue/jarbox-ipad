package javax.microedition.lcdui;

import java.util.ArrayList;

public class Form extends Screen {
    private final ArrayList<Item> items = new ArrayList<Item>();
    private ItemStateListener itemStateListener;

    public Form(String title) {
        setTitle(title);
    }

    public Form(String title, Item[] itemArray) {
        setTitle(title);
        if (itemArray != null) for (int i = 0; i < itemArray.length; i++) append(itemArray[i]);
    }

    private void adopt(Item item) {
        if (item == null) throw new NullPointerException();
        if (item.owner != null) throw new IllegalStateException();
        item.owner = this;
    }

    private void checkIndex(int i, int limit) {
        if (i < 0 || i >= limit) throw new IndexOutOfBoundsException();
    }

    public int append(Item item) {
        adopt(item);
        items.add(item);
        midpContentChanged();
        return items.size() - 1;
    }

    public int append(String str) {
        if (str == null) throw new NullPointerException();
        return append(new StringItem(null, str));
    }

    public int append(Image img) {
        if (img == null) throw new NullPointerException();
        return append(new ImageItem(null, img, ImageItem.LAYOUT_DEFAULT, null));
    }

    public void insert(int index, Item item) {
        checkIndex(index, items.size() + 1);
        adopt(item);
        items.add(index, item);
        midpContentChanged();
    }

    public void set(int index, Item item) {
        checkIndex(index, items.size());
        adopt(item);
        items.set(index, item).owner = null;
        midpContentChanged();
    }

    public void delete(int index) {
        checkIndex(index, items.size());
        items.remove(index).owner = null;
        midpContentChanged();
    }

    public void deleteAll() {
        for (int i = 0; i < items.size(); i++) items.get(i).owner = null;
        items.clear();
        midpContentChanged();
    }

    public int size() { return items.size(); }

    public Item get(int index) {
        checkIndex(index, items.size());
        return items.get(index);
    }

    public void setItemStateListener(ItemStateListener listener) { itemStateListener = listener; }

    void midpNotifyItemState(Item item) {
        if (itemStateListener != null) itemStateListener.itemStateChanged(item);
    }

    @Override
    void midpWrite(ScreenWriter out) {
        out.field("kind", "form");
        out.beginArray("items");
        for (int i = 0; i < items.size(); i++) items.get(i).midpWriteTo(out);
        out.endArray();
    }

    @Override
    void midpNativeValue(int index, String value) {
        if (index < 0 || index >= items.size()) return;
        Item item = items.get(index);
        if (item.midpNativeValue(value)) midpNotifyItemState(item);
    }

    @Override
    void midpItemCommand(int itemIndex, int commandIndex) {
        if (itemIndex >= 0 && itemIndex < items.size()) items.get(itemIndex).midpFireItemCommand(commandIndex);
    }
}
