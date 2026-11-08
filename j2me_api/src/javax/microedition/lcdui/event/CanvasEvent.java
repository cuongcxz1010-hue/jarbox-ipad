package javax.microedition.lcdui.event;

import javax.microedition.lcdui.Canvas;
import javax.microedition.util.ArrayStack;

public class CanvasEvent extends Event {
	private static final ArrayStack<CanvasEvent> recycled = new ArrayStack<>();

	public static final int KEY_PRESSED = 0;
	public static final int KEY_REPEATED = 1;
	public static final int KEY_RELEASED = 2;
	public static final int POINTER_PRESSED = 3;
	public static final int POINTER_DRAGGED = 4;
	public static final int POINTER_RELEASED = 5;

	private static final int[] enqueued = new int[6];

	private Canvas canvas;
	private int eventType;
	private int keyCode;
	private int x, y;

	public static Event getInstance(Canvas canvas, int eventType, int keyCode) {
		CanvasEvent instance = obtain(canvas, eventType);
		instance.keyCode = keyCode;
		return instance;
	}

	public static Event getInstance(Canvas canvas, int eventType, int pointer, float x, float y) {
		CanvasEvent instance = obtain(canvas, eventType);
		instance.x = Math.round(x);
		instance.y = Math.round(y);
		return instance;
	}

	private static CanvasEvent obtain(Canvas canvas, int eventType) {
		CanvasEvent instance;
		synchronized (recycled) {
			instance = recycled.pop();
		}
		if (instance == null) {
			instance = new CanvasEvent();
		}
		instance.canvas = canvas;
		instance.eventType = eventType;
		return instance;
	}

	@Override
	public void process() {
		try {
			switch (eventType) {
				case KEY_PRESSED:      canvas.doKeyPressed(keyCode); break;
				case KEY_REPEATED:     canvas.doKeyRepeated(keyCode); break;
				case KEY_RELEASED:     canvas.doKeyReleased(keyCode); break;
				case POINTER_PRESSED:  canvas.doPointerPressed(x, y); break;
				case POINTER_DRAGGED:  canvas.doPointerDragged(x, y); break;
				case POINTER_RELEASED: canvas.doPointerReleased(x, y); break;
			}
		} catch (Throwable t) {
			System.out.println("[Canvas] Error in input callback: " + t);
			t.printStackTrace();
		}
	}

	@Override
	public void recycle() {
		canvas = null;
		synchronized (recycled) {
			recycled.push(this);
		}
	}

	@Override
	public void enterQueue() {
		enqueued[eventType]++;
	}

	@Override
	public void leaveQueue() {
		enqueued[eventType]--;
	}

	@Override
	public boolean placeableAfter(Event event) {
		if (event instanceof CanvasEvent) {
			switch (eventType) {
				case KEY_REPEATED:
				case POINTER_DRAGGED:
					return enqueued[eventType] < 2;
			}
		}
		return true;
	}
}
