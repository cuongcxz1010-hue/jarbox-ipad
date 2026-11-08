package org.jarbox.net;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;

import javax.microedition.io.Datagram;

final class DatagramImpl implements Datagram {
    private byte[] data;
    private int offset, length;
    private int cursor;
    String host;
    int port;

    DatagramImpl(byte[] data, int length) {
        this.data = data;
        this.length = length;
    }

    public String getAddress() { return host == null ? null : "datagram://" + host + ":" + port; }

    public void setAddress(String addr) throws IOException {
        if (addr == null) throw new IllegalArgumentException();
        String a = addr;
        if (a.startsWith("datagram://")) a = a.substring(11);
        else if (a.startsWith("//")) a = a.substring(2);
        int colon = a.lastIndexOf(':');
        if (colon <= 0) throw new IllegalArgumentException(addr);
        try {
            port = Integer.parseInt(a.substring(colon + 1));
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(addr);
        }
        host = a.substring(0, colon);
    }

    public void setAddress(Datagram reference) {
        DatagramImpl d = (DatagramImpl) reference;
        host = d.host;
        port = d.port;
    }

    public byte[] getData() { return data; }
    public int getOffset() { return offset; }
    public int getLength() { return length; }

    public void setLength(int len) {
        if (len < 0 || offset + len > data.length) throw new IllegalArgumentException();
        length = len;
    }

    public void setData(byte[] buffer, int off, int len) {
        if (off < 0 || len < 0 || off + len > buffer.length) throw new IllegalArgumentException();
        data = buffer;
        offset = off;
        length = len;
        cursor = 0;
    }

    public void reset() { cursor = 0; }

    // DataInput / DataOutput over the data array, with an independent cursor
    private DataInputStream input(int bytes) throws IOException {
        if (cursor + bytes > length) throw new java.io.EOFException();
        return new DataInputStream(new ByteArrayInputStream(data, offset + cursor, length - cursor));
    }

    public boolean readBoolean() throws IOException { return readByte() != 0; }

    public byte readByte() throws IOException {
        if (cursor >= length) throw new java.io.EOFException();
        return data[offset + cursor++];
    }

    public char readChar() throws IOException { char v = input(2).readChar(); cursor += 2; return v; }
    public double readDouble() throws IOException { double v = input(8).readDouble(); cursor += 8; return v; }
    public float readFloat() throws IOException { float v = input(4).readFloat(); cursor += 4; return v; }
    public void readFully(byte[] b) throws IOException { readFully(b, 0, b.length); }

    public void readFully(byte[] b, int off, int len) throws IOException {
        if (cursor + len > length) throw new java.io.EOFException();
        System.arraycopy(data, offset + cursor, b, off, len);
        cursor += len;
    }

    public int readInt() throws IOException { int v = input(4).readInt(); cursor += 4; return v; }
    public long readLong() throws IOException { long v = input(8).readLong(); cursor += 8; return v; }
    public short readShort() throws IOException { short v = input(2).readShort(); cursor += 2; return v; }
    public int readUnsignedByte() throws IOException { return readByte() & 0xFF; }
    public int readUnsignedShort() throws IOException { return readShort() & 0xFFFF; }

    public String readUTF() throws IOException {
        DataInputStream in = input(2);
        int before = in.available();
        String v = in.readUTF();
        cursor += before - in.available();
        return v;
    }

    public String readLine() throws IOException { throw new IOException("readLine is not supported"); }

    public int skipBytes(int n) throws IOException {
        int k = Math.min(n, length - cursor);
        cursor += k;
        return k;
    }

    private void put(byte[] bytes) throws IOException {
        if (offset + cursor + bytes.length > data.length) throw new IOException("datagram is full");
        System.arraycopy(bytes, 0, data, offset + cursor, bytes.length);
        cursor += bytes.length;
        if (cursor > length) length = cursor;
    }

    private byte[] encoded(Encoder e) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream(16);
        DataOutputStream out = new DataOutputStream(buf);
        e.write(out);
        out.flush();
        return buf.toByteArray();
    }

    private interface Encoder {
        void write(DataOutputStream out) throws IOException;
    }

    public void write(byte[] b) throws IOException { put(b.clone()); }

    public void write(byte[] b, int off, int len) throws IOException {
        byte[] part = new byte[len];
        System.arraycopy(b, off, part, 0, len);
        put(part);
    }

    public void write(int b) throws IOException { put(new byte[]{(byte) b}); }
    public void writeBoolean(boolean v) throws IOException { write(v ? 1 : 0); }
    public void writeByte(int v) throws IOException { write(v); }

    public void writeBytes(final String s) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeBytes(s); } }));
    }

    public void writeChar(final int v) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeChar(v); } }));
    }

    public void writeChars(final String s) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeChars(s); } }));
    }

    public void writeDouble(final double v) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeDouble(v); } }));
    }

    public void writeFloat(final float v) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeFloat(v); } }));
    }

    public void writeInt(final int v) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeInt(v); } }));
    }

    public void writeLong(final long v) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeLong(v); } }));
    }

    public void writeShort(final int v) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeShort(v); } }));
    }

    public void writeUTF(final String s) throws IOException {
        put(encoded(new Encoder() { public void write(DataOutputStream o) throws IOException { o.writeUTF(s); } }));
    }
}
