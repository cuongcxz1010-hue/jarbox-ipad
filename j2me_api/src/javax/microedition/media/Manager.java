package javax.microedition.media;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import javax.microedition.lcdui.NativeBridge;
import javax.microedition.media.tone.ToneManager;

public class Manager {
    public static final String TONE_DEVICE_LOCATOR = "device://tone";
    public static final String MIDI_DEVICE_LOCATOR = "device://midi";

    /** False when the user turned this game's sound off. */
    static boolean soundEnabled() {
        return !"0".equals(System.getProperty("j2me.sound.enabled"));
    }

    public static Player createPlayer(InputStream stream, String type) throws IOException, MediaException {
        if (stream == null) throw new IllegalArgumentException("stream is null");
        byte[] data = readAllBytes(stream);
        if (type != null && type.contains("tone")) {
            TonePlayer tone = new TonePlayer();
            tone.setSequence(data);
            return tone;
        }
        if (type != null && (type.contains("midi") || type.contains("mid") || type.contains("sp-midi"))) {
            return new MidiPlayer(data);
        }
        return new MicroPlayer(data);
    }

    public static Player createPlayer(String locator) throws IOException, MediaException {
        if (locator == null) throw new IllegalArgumentException("locator is null");
        if (locator.equals(TONE_DEVICE_LOCATOR)) {
            return new TonePlayer();
        }
        if (locator.equals(MIDI_DEVICE_LOCATOR)) {
            return new MidiPlayer(null);
        }
        // Try to open as resource or URL
        if (locator.startsWith("http://") || locator.startsWith("https://")) {
            javax.microedition.io.HttpConnection conn = (javax.microedition.io.HttpConnection)
                javax.microedition.io.Connector.open(locator);
            InputStream is = conn.openInputStream();
            byte[] data = readAllBytes(is);
            is.close();
            conn.close();
            return new MicroPlayer(data);
        }
        if (locator.startsWith("resource:")) {
            InputStream is = javax.microedition.util.GameResources.open(locator.substring(9));
            if (is == null) throw new IOException("not found: " + locator);
            String type = locator.toLowerCase().endsWith(".mid") || locator.toLowerCase().endsWith(".midi") ? "audio/midi" : "audio/wav";
            return createPlayer(is, type);
        }
        throw new MediaException("Unsupported locator: " + locator);
    }

    public static void playTone(int note, int duration, int volume) throws MediaException {
        if (note < 0 || note > 127 || duration <= 0) throw new IllegalArgumentException();
        if (!soundEnabled()) return;
        ToneManager.play(note, duration, volume);
    }

    public static String[] getSupportedContentTypes(String protocol) {
        return new String[]{
            "audio/wav", "audio/x-wav",
            "audio/mpeg", "audio/mp3",
            "audio/midi", "audio/x-midi", "audio/sp-midi",
            "audio/x-tone-seq",
            "audio/amr", "audio/3gpp"
        };
    }

    public static String[] getSupportedProtocols(String contentType) {
        return new String[]{"device", "http", "https", "resource"};
    }

    private static byte[] readAllBytes(InputStream is) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream(4096);
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
        is.close();
        return bos.toByteArray();
    }
}
