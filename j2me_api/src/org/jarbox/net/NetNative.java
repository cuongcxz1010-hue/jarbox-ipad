package org.jarbox.net;

/** Socket operations implemented in net_natives.c. */
final class NetNative {
    static final int OPT_DELAY = 0, OPT_LINGER = 1, OPT_KEEPALIVE = 2, OPT_RCVBUF = 3, OPT_SNDBUF = 4, OPT_READ_TIMEOUT = 5;
    static final int EOF = -1, TIMEOUT = -2, ERROR = -3;

    private NetNative() { }

    static native long tcpConnect(String host, int port, int timeoutMs);
    static native int tcpRead(long handle, byte[] data, int offset, int length);
    static native int tcpWrite(long handle, byte[] data, int offset, int length);
    static native int tcpAvailable(long handle);
    static native void close(long handle);
    static native int setOption(long handle, int option, int value);
    static native int getOption(long handle, int option);
    static native String address(long handle, int remote);
    static native int port(long handle, int remote);
    static native long udpOpen(int localPort);
    static native int udpSend(long handle, String host, int port, byte[] data, int offset, int length);
    static native int udpReceive(long handle, byte[] data, int offset, int length, String[] sender);
    static native long serverOpen(int port);
    static native long serverAccept(long handle);
}
