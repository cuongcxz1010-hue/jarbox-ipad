package javax.microedition.lcdui.keyboard;

import java.util.HashMap;

import javax.microedition.lcdui.Canvas;

/**
 * Key codes of the different phone families. The on-screen keyboard and the
 * platform always speak Nokia codes; this class converts them to what the
 * selected family reports, and answers getGameAction / getKeyCode / getKeyName.
 *
 * The profile comes from the system property j2me.keyboard.layout:
 *   0 Nokia (also the default of most Java phones)
 *   1 Siemens
 *   2 Motorola
 *   3 Samsung
 *   4 Sony Ericsson
 *   5 Nokia E62 (QWERTY: digits sit on letter keys)
 * Per-game remapping comes from j2me.keyboard.remap, "from:to,from:to".
 */
public final class KeyMapper {
    public static final int NOKIA = 0, SIEMENS = 1, MOTOROLA = 2, SAMSUNG = 3, SONY_ERICSSON = 4, NOKIA_E62 = 5;

    public static final int SE_KEY_SPECIAL_GAMING_A = -13;
    public static final int SE_KEY_SPECIAL_GAMING_B = -14;

    private static final HashMap<Integer, Integer> toDevice = new HashMap<Integer, Integer>();
    private static final HashMap<Integer, Integer> gameActions = new HashMap<Integer, Integer>();
    private static final HashMap<Integer, Integer> actionKeys = new HashMap<Integer, Integer>();
    private static final HashMap<Integer, String> names = new HashMap<Integer, String>();

    private static int layout;

    static {
        layout = intProperty("j2me.keyboard.layout", NOKIA);
        build();
        parseRemap(System.getProperty("j2me.keyboard.remap"));
    }

    private KeyMapper() { }

    private static int intProperty(String key, int fallback) {
        String v = System.getProperty(key);
        if (v != null) {
            try {
                return Integer.parseInt(v);
            } catch (NumberFormatException e) {
                // keep the default
            }
        }
        return fallback;
    }

    private static void map(int from, int to) { toDevice.put(from, to); }

    private static void named(int code, int action, String name) {
        gameActions.put(code, action);
        names.put(code, name);
    }

    private static void action(int gameAction, int code) { actionKeys.put(gameAction, code); }

    private static void build() {
        gameActions.put(Canvas.KEY_NUM0, 0);
        gameActions.put(Canvas.KEY_NUM1, 0);
        gameActions.put(Canvas.KEY_NUM2, Canvas.UP);
        gameActions.put(Canvas.KEY_NUM3, 0);
        gameActions.put(Canvas.KEY_NUM4, Canvas.LEFT);
        gameActions.put(Canvas.KEY_NUM5, Canvas.FIRE);
        gameActions.put(Canvas.KEY_NUM6, Canvas.RIGHT);
        gameActions.put(Canvas.KEY_NUM7, Canvas.GAME_A);
        gameActions.put(Canvas.KEY_NUM8, Canvas.DOWN);
        gameActions.put(Canvas.KEY_NUM9, Canvas.GAME_B);
        gameActions.put(Canvas.KEY_STAR, Canvas.GAME_C);
        gameActions.put(Canvas.KEY_POUND, Canvas.GAME_D);

        for (int d = 0; d <= 9; d++) names.put(Canvas.KEY_NUM0 + d, String.valueOf(d));
        names.put(Canvas.KEY_STAR, "*");
        names.put(Canvas.KEY_POUND, "#");

        named(Canvas.KEY_UP, Canvas.UP, "UP");
        named(Canvas.KEY_DOWN, Canvas.DOWN, "DOWN");
        named(Canvas.KEY_LEFT, Canvas.LEFT, "LEFT");
        named(Canvas.KEY_RIGHT, Canvas.RIGHT, "RIGHT");
        named(Canvas.KEY_FIRE, Canvas.FIRE, "SELECT");
        named(Canvas.KEY_SOFT_LEFT, 0, "SOFT1");
        named(Canvas.KEY_SOFT_RIGHT, 0, "SOFT2");
        named(Canvas.KEY_CLEAR, 0, "CLEAR");
        named(Canvas.KEY_SEND, 0, "SEND");
        named(Canvas.KEY_END, 0, "END");

        action(Canvas.UP, Canvas.KEY_UP);
        action(Canvas.DOWN, Canvas.KEY_DOWN);
        action(Canvas.LEFT, Canvas.KEY_LEFT);
        action(Canvas.RIGHT, Canvas.KEY_RIGHT);
        action(Canvas.FIRE, Canvas.KEY_FIRE);
        action(Canvas.GAME_A, Canvas.KEY_NUM7);
        action(Canvas.GAME_B, Canvas.KEY_NUM9);
        action(Canvas.GAME_C, Canvas.KEY_STAR);
        action(Canvas.GAME_D, Canvas.KEY_POUND);

        switch (layout) {
            case SIEMENS: {
                final int up = -59, down = -60, left = -61, right = -62, softL = -1, softR = -4;
                remapArrows(up, down, left, right, Canvas.KEY_FIRE, softL, softR);
                break;
            }
            case MOTOROLA: {
                final int up = -1, down = -6, left = -2, right = -5, fire = -20, softL = -21, softR = -22;
                remapArrows(up, down, left, right, fire, softL, softR);
                break;
            }
            case SONY_ERICSSON:
                named(SE_KEY_SPECIAL_GAMING_A, Canvas.GAME_A, "GAME A");
                named(SE_KEY_SPECIAL_GAMING_B, Canvas.GAME_B, "GAME B");
                break;
            case NOKIA_E62: {
                final int[] digits = {109, 114, 116, 121, 102, 103, 104, 118, 98, 110};
                for (int d = 0; d <= 9; d++) map(Canvas.KEY_NUM0 + d, digits[d]);
                map(Canvas.KEY_STAR, 117);
                map(Canvas.KEY_POUND, 106);
                break;
            }
            default:        // Nokia and Samsung use the standard codes
                break;
        }
    }

    private static void remapArrows(int up, int down, int left, int right, int fire, int softL, int softR) {
        map(Canvas.KEY_UP, up);
        map(Canvas.KEY_DOWN, down);
        map(Canvas.KEY_LEFT, left);
        map(Canvas.KEY_RIGHT, right);
        map(Canvas.KEY_FIRE, fire);
        map(Canvas.KEY_SOFT_LEFT, softL);
        map(Canvas.KEY_SOFT_RIGHT, softR);

        action(Canvas.UP, up);
        action(Canvas.DOWN, down);
        action(Canvas.LEFT, left);
        action(Canvas.RIGHT, right);
        action(Canvas.FIRE, fire);

        named(up, Canvas.UP, "UP");
        named(down, Canvas.DOWN, "DOWN");
        named(left, Canvas.LEFT, "LEFT");
        named(right, Canvas.RIGHT, "RIGHT");
        named(fire, Canvas.FIRE, "SELECT");
        named(softL, 0, "SOFT1");
        named(softR, 0, "SOFT2");
    }

    private static void parseRemap(String spec) {
        if (spec == null || spec.length() == 0) return;
        int pos = 0;
        while (pos < spec.length()) {
            int comma = spec.indexOf(',', pos);
            String pair = comma < 0 ? spec.substring(pos) : spec.substring(pos, comma);
            int colon = pair.indexOf(':');
            if (colon > 0) {
                try {
                    int from = Integer.parseInt(pair.substring(0, colon).trim());
                    int to = Integer.parseInt(pair.substring(colon + 1).trim());
                    map(from, to);
                } catch (NumberFormatException e) {
                    System.out.println("[KeyMapper] bad remap entry: " + pair);
                }
            }
            if (comma < 0) break;
            pos = comma + 1;
        }
    }

    public static int convertKeyCode(int keyCode) {
        Integer mapped = toDevice.get(keyCode);
        return mapped != null ? mapped : keyCode;
    }

    /** Integer.MAX_VALUE when the code is unknown. */
    public static int getGameAction(int keyCode) {
        Integer a = gameActions.get(keyCode);
        if (a != null) return a;
        // Character keys (from a hardware keyboard) and unknown device codes have no action
        return 0;
    }

    public static int getKeyCode(int gameAction) {
        Integer c = actionKeys.get(gameAction);
        return c != null ? c : Integer.MAX_VALUE;
    }

    public static String getKeyName(int keyCode) {
        String name = names.get(keyCode);
        if (name != null) return name;
        if (keyCode > 0 && keyCode < 0x10000) return String.valueOf((char) keyCode);
        return "KEY " + keyCode;
    }
}
