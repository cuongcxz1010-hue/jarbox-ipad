package org.jarbox.net;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;

import javax.microedition.io.Connector;
import javax.microedition.io.SocketConnection;

/**
 * socket:// connection. Reads go through a small buffer: games read their
 * packets byte by byte through DataInputStream, and without it every byte
 * would cost a system call. Bytes are passed through unchanged.
 */
public final class TcpConnection implements SocketConnection {
    private static final int DEFAULT_CONNECT_TIMEOUT_MS = 30000;
    private static final int BUFFER_SIZE = 8192;

    private final long handle;
    private final String remoteHost;
    private final int remotePort;
    private final int mode;
    private volatile boolean closed;
    private boolean inputOpened, outputOpened;
    private int delay = 1;

    public TcpConnection(String host, int port, int mode) throws IOException {
        long h = NetNative.tcpConnect(host, port, DEFAULT_CONNECT_TIMEOUT_MS);
        if (h == NetNative.TIMEOUT) throw new InterruptedIOException("connect timed out: " + host + ":" + port);
        if (h < 0) throw new IOException("connect failed: " + host + ":" + port);
        this.handle = h;
        this.remoteHost = host;
        this.remotePort = port;
        this.mode = mode;
    }

    /** A connection accepted by a server socket. */
    TcpConnection(long handle, int mode) {
        this.handle = handle;
        this.remoteHost = NetNative.address(handle, 1);
        this.remotePort = NetNative.port(handle, 1);
        this.mode = mode;
    }

    private void ensureOpen() throws IOException {
        if (closed) throw new IOException("connection closed");
    }

    public synchronized InputStream openInputStream() throws IOException {
        ensureOpen();
        if ((mode & Connector.READ) == 0) throw new IOException("connection not open for reading");
        if (inputOpened) throw new IOException("input stream already opened");
        inputOpened = true;
        return new In();
    }

    public DataInputStream openDataInputStream() throws IOException {
        return new DataInputStream(openInputStream());
    }

    public synchronized OutputStream openOutputStream() throws IOException {
        ensureOpen();
        if ((mode & Connector.WRITE) == 0) throw new IOException("connection not open for writing");
        if (outputOpened) throw new IOException("output stream already opened");
        outputOpened = true;
        return new Out();
    }

    public DataOutputStream openDataOutputStream() throws IOException {
        return new DataOutputStream(openOutputStream());
    }

    public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        NetNative.close(handle);
    }

    private static int toNative(byte option) {
        switch (option) {
            case DELAY: return NetNative.OPT_DELAY;
            case LINGER: return NetNative.OPT_LINGER;
            case KEEPALIVE: return NetNative.OPT_KEEPALIVE;
            case RCVBUF: return NetNative.OPT_RCVBUF;
            case SNDBUF: return NetNative.OPT_SNDBUF;
            default: throw new IllegalArgumentException("option " + option);
        }
    }

    public void setSocketOption(byte option, int value) throws IllegalArgumentException, IOException {
        ensureOpen();
        if (value < 0) throw new IllegalArgumentException();
        if (option == DELAY) delay = value;
        NetNative.setOption(handle, toNative(option), value);
    }

    public int getSocketOption(byte option) throws IllegalArgumentException, IOException {
        ensureOpen();
        if (option == DELAY) return delay;
        return NetNative.getOption(handle, toNative(option));
    }

    public String getLocalAddress() throws IOException {
        ensureOpen();
        return NetNative.address(handle, 0);
    }

    public int getLocalPort() throws IOException {
        ensureOpen();
        return NetNative.port(handle, 0);
    }

    public String getAddress() throws IOException {
        ensureOpen();
        return remoteHost;
    }

    public int getPort() throws IOException {
        ensureOpen();
        return remotePort;
    }

    private final class In extends InputStream {
        private final byte[] buffer = new byte[BUFFER_SIZE];
        private int position, limit;
        private boolean streamClosed;

        private boolean fill() throws IOException {
            if (streamClosed || closed) throw new IOException("stream closed");
            int n = NetNative.tcpRead(handle, buffer, 0, BUFFER_SIZE);
            if (n == NetNative.EOF) return false;
            if (n == NetNative.TIMEOUT) throw new InterruptedIOException("read timed out");
            if (n < 0) throw new IOException("connection lost");
            position = 0;
            limit = n;
            return true;
        }

        public int read() throws IOException {
            if (position >= limit && !fill()) return -1;
            return buffer[position++] & 0xFF;
        }

        public int read(byte[] b, int offset, int length) throws IOException {
            if (b == null) throw new NullPointerException();
            if (offset < 0 || length < 0 || offset + length > b.length) throw new IndexOutOfBoundsException();
            if (length == 0) return 0;
            if (position >= limit && !fill()) return -1;
            int n = limit - position;
            if (n > length) n = length;
            System.arraycopy(buffer, position, b, offset, n);
            position += n;
            return n;
        }

        public int available() throws IOException {
            if (streamClosed || closed) throw new IOException("stream closed");
            return (limit - position) + NetNative.tcpAvailable(handle);
        }

        public void close() { streamClosed = true; }
    }

    private final class Out extends OutputStream {
        private final byte[] single = new byte[1];
        private boolean streamClosed;

        public void write(int b) throws IOException {
            single[0] = (byte) b;
            write(single, 0, 1);
        }

        public void write(byte[] b, int offset, int length) throws IOException {
            if (b == null) throw new NullPointerException();
            if (offset < 0 || length < 0 || offset + length > b.length) throw new IndexOutOfBoundsException();
            if (streamClosed || closed) throw new IOException("stream closed");
            if (length == 0) return;
            int n = NetNative.tcpWrite(handle, b, offset, length);
            if (n < 0) throw new IOException("connection lost");
        }

        public void close() { streamClosed = true; }
    }
}
