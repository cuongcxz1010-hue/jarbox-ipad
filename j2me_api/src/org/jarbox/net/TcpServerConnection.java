package org.jarbox.net;

import java.io.IOException;

import javax.microedition.io.Connector;
import javax.microedition.io.ServerSocketConnection;
import javax.microedition.io.StreamConnection;

/** socket://:port server connection. */
public final class TcpServerConnection implements ServerSocketConnection {
    private final long handle;
    private volatile boolean closed;

    public TcpServerConnection(int port) throws IOException {
        long h = NetNative.serverOpen(port);
        if (h < 0) throw new IOException("cannot listen on port " + port);
        handle = h;
    }

    public StreamConnection acceptAndOpen() throws IOException {
        if (closed) throw new IOException("connection closed");
        long client = NetNative.serverAccept(handle);
        if (client < 0) throw new IOException("accept failed");
        return new TcpConnection(client, Connector.READ_WRITE);
    }

    public String getLocalAddress() throws IOException { return NetNative.address(handle, 0); }
    public int getLocalPort() throws IOException { return NetNative.port(handle, 0); }

    public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        NetNative.close(handle);
    }
}
