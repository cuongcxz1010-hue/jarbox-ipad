package org.jarbox.net;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.util.Date;

import javax.microedition.lcdui.NativeBridge;
import javax.wireless.messaging.BinaryMessage;
import javax.wireless.messaging.Message;
import javax.wireless.messaging.MessageConnection;
import javax.wireless.messaging.MessageListener;
import javax.wireless.messaging.TextMessage;

/**
 * sms:// connection. iOS does not let an app send SMS by itself, so a text
 * message is handed to the Messages app for the user to confirm. Receiving
 * is not possible.
 */
public final class SmsConnection implements MessageConnection {
    private final String defaultAddress;

    public SmsConnection(String url) { defaultAddress = url; }

    public Message newMessage(String type) { return newMessage(type, defaultAddress); }

    public Message newMessage(String type, String address) {
        if (BINARY_MESSAGE.equals(type)) return new Binary(address);
        return new Text(address);
    }

    public void send(Message msg) throws IOException {
        if (msg == null) throw new NullPointerException();
        if (!(msg instanceof TextMessage)) throw new IOException("binary SMS is not available on iOS");
        String address = msg.getAddress();
        if (address == null) throw new IllegalArgumentException("no address");
        String number = address;
        if (number.startsWith("sms://")) number = number.substring(6);
        int colon = number.indexOf(':');
        if (colon >= 0) number = number.substring(0, colon);
        String body = ((TextMessage) msg).getPayloadText();
        NativeBridge.platformRequest("sms:" + number + "&body=" + encode(body == null ? "" : body));
    }

    private static String encode(String s) throws IOException {
        byte[] bytes = s.getBytes("UTF-8");
        StringBuffer out = new StringBuffer(bytes.length + 16);
        for (int i = 0; i < bytes.length; i++) {
            int b = bytes[i] & 0xFF;
            if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '-' || b == '_' || b == '.') {
                out.append((char) b);
            } else {
                out.append('%').append(Character.forDigit(b >> 4, 16)).append(Character.forDigit(b & 15, 16));
            }
        }
        return out.toString();
    }

    public Message receive() throws IOException { throw new InterruptedIOException("receiving SMS is not available on iOS"); }
    public void setMessageListener(MessageListener listener) throws IOException { }
    public int numberOfSegments(Message msg) { return 1; }
    public void close() throws IOException { }

    private static class Base implements Message {
        private String address;
        Base(String address) { this.address = address; }
        public String getAddress() { return address; }
        public void setAddress(String addr) { address = addr; }
        public Date getTimestamp() { return new Date(); }
    }

    private static final class Text extends Base implements TextMessage {
        private String payload;
        Text(String address) { super(address); }
        public String getPayloadText() { return payload; }
        public void setPayloadText(String data) { payload = data; }
    }

    private static final class Binary extends Base implements BinaryMessage {
        private byte[] payload;
        Binary(String address) { super(address); }
        public byte[] getPayloadData() { return payload; }
        public void setPayloadData(byte[] data) { payload = data; }
    }
}
