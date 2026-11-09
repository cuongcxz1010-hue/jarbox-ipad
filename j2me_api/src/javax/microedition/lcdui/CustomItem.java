/*
 * Copyright 2018 Nikita Shakarun
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package javax.microedition.lcdui;

public abstract class CustomItem extends Item {
	protected static final int KEY_PRESS = 4;
	protected static final int KEY_RELEASE = 8;
	protected static final int KEY_REPEAT = 16;
	protected static final int NONE = 0;
	protected static final int POINTER_DRAG = 128;
	protected static final int POINTER_PRESS = 32;
	protected static final int POINTER_RELEASE = 64;
	protected static final int TRAVERSE_HORIZONTAL = 1;
	protected static final int TRAVERSE_VERTICAL = 2;

	protected CustomItem(String label) {
		setLabel(label);
	}

	public int getGameAction(int keyCode) {
		return 0;
	}

	protected final int getInteractionModes() {
		return 0;
	}

	protected abstract int getMinContentWidth();

	protected abstract int getMinContentHeight();

	protected abstract int getPrefContentWidth(int height);

	protected abstract int getPrefContentHeight(int width);

	protected abstract void paint(Graphics g, int w, int h);

	protected void sizeChanged(int w, int h) {
	}

	protected final void invalidate() {
		midpChanged();
	}

	protected final void repaint() {
		repaint(0, 0, getMinContentWidth(), getMinContentHeight());
	}

	protected final void repaint(int x, int y, int width, int height) {
		midpChanged();
	}

	protected boolean traverse(int dir, int viewportWidth, int viewportHeight, int[] visRect_inout) {
		return false;
	}

	protected void traverseOut() {
	}

	protected void showNotify() {
	}

	protected void hideNotify() {
	}

	protected void keyPressed(int keyCode) {
	}

	protected void keyRepeated(int keyCode) {
	}

	protected void keyReleased(int keyCode) {
	}

	protected void pointerPressed(int x, int y) {
	}

	protected void pointerDragged(int x, int y) {
	}

	protected void pointerReleased(int x, int y) {
	}

	@Override
	void midpWrite(ScreenWriter out) {
		int w = Math.max(getMinContentWidth(), getPrefContentWidth(-1));
		int h = Math.max(getMinContentHeight(), getPrefContentHeight(w));
		if (w <= 0) w = 1;
		if (h <= 0) h = 1;
		Image canvas = Image.createImage(w, h);
		try {
			paint(canvas.getGraphics(), w, h);
		} catch (Throwable t) {
			System.out.println("[CustomItem] paint: " + t);
		}
		out.field("kind", "custom");
		out.image("image", canvas);
		out.field("width", w);
		out.field("height", h);
	}
}
