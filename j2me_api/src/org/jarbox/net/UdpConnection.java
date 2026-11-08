package org.jarbox.net;

import java.io.IOException;
import java.io.InterruptedIOException;

import javax.microedition.io.Datagram;
import javax.microedition.io.UDPDatagramConnection;

/** datagram:// connection. */
public final class UdpConnection implements UDPDatagramConnection {
    private static final int MAX_LENGTH = 1500;

    private final long handle;
    private final String defaultHost;
    private final int defaultPort;
    private volatile boolean closed;

    /** @param host null for a connection that only receives on {@code port} */
    public UdpConnection(String host, int port) throws IOException {
        long h = NetNative.udpOpen(host == null ? port : 0);
        if (h < 0) throw new IOException("cannot open datagram socket");
        handle = h;
        defaultHost = host;
        defaultPort = port;
    }

    private void ensureOpen() throws IOException {
        if (closed) throw new IOException("connection closed");
    }

    public int getMaximumLength() throws IOException { return MAX_LENGTH; }
    public int getNominalLength() throws IOException { return MAX_LENGTH; }

    public void send(Datagram dgram) throws IOException {
        ensureOpen();
        DatagramImpl d = (DatagramImpl) dgram;
        String host = d.host != null ? d.host : defaultHost;
        int port = d.host != null ? d.port : defaultPort;
        if (host == null) throw new IOException("no destination address");
        int n = NetNative.udpSend(handle, host, port, d.getData(), d.getOffset(), d.getLength());
        if (n < 0) throw new IOException("send failed");
    }

    public void receive(Datagram dgram) throws IOException {
        ensureOpen();
        DatagramImpl d = (DatagramImpl) dgram;
        String[] sender = new String[1];
        int n = NetNative.udpReceive(handle, d.getData(), d.getOffset(), d.getData().length - d.getOffset(), sender);
        if (n == NetNative.TIMEOUT) throw new InterruptedIOException("receive timed out");
        if (n < 0) throw new IOException("receive failed");
        d.setLength(n);
        if (sender[0] != null) {
            int colon = sender[0].lastIndexOf(':');
            d.host = sender[0].substring(0, colon);
            d.port = Integer.parseInt(sender[0].substring(colon + 1));
        }
        d.reset();
    }

    public Datagram newDatagram(int size) throws IOException { return newDatagram(new byte[size], size); }

    public Datagram newDatagram(int size, String addr) throws IOException { return newDatagram(new byte[size], size, addr); }

    public Datagram newDatagram(byte[] buf, int size) throws IOException {
        if (size < 0 || size > buf.length) throw new IllegalArgumentException();
        return new DatagramImpl(buf, size);
    }

    public Datagram newDatagram(byte[] buf, int size, String addr) throws IOException {
        Datagram d = newDatagram(buf, size);
        d.setAddress(addr);
        return d;
    }

    public String getLocalAddress() throws IOException { return NetNative.address(handle, 0); }
    public int getLocalPort() throws IOException { return NetNative.port(handle, 0); }

    public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        NetNative.close(handle);
    }
}
