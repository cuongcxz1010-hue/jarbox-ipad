package javax.microedition.io;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

import org.jarbox.net.SmsConnection;
import org.jarbox.net.TcpConnection;
import org.jarbox.net.TcpServerConnection;
import org.jarbox.net.UdpConnection;

/**
 * Generic Connection Framework. Sockets and datagrams are implemented in
 * org.jarbox.net; HTTP and HTTPS by the runtime's Protocol classes.
 */
public class Connector {

	public static final int READ = 1;
	public static final int WRITE = 2;
	public static final int READ_WRITE = 3;

	private Connector() { }

	public static Connection open(String name) throws IOException {
		return open(name, READ_WRITE, false);
	}

	public static Connection open(String name, int mode) throws IOException {
		return open(name, mode, false);
	}

	public static Connection open(String name, int mode, boolean timeouts) throws IOException {
		if (name == null) throw new IllegalArgumentException("null URL");
		if (mode != READ && mode != WRITE && mode != READ_WRITE) throw new IllegalArgumentException("bad mode");
		int colon = name.indexOf(':');
		if (colon < 1) throw new IllegalArgumentException("no protocol in URL: " + name);
		String protocol = name.substring(0, colon).toLowerCase();
		String target = name.substring(colon + 1);

		if (protocol.equals("socket")) return openSocket(target, mode);
		if (protocol.equals("serversocket")) return new TcpServerConnection(parsePort(afterSlashes(target), target));
		if (protocol.equals("datagram")) return openDatagram(target);
		if (protocol.equals("sms") || protocol.equals("mms")) return new SmsConnection(name);
		if (protocol.equals("http") || protocol.equals("https")) return openRuntimeProtocol(protocol, target, mode, timeouts);
		throw new ConnectionNotFoundException("protocol not supported: " + protocol);
	}

	private static String afterSlashes(String target) {
		return target.startsWith("//") ? target.substring(2) : target;
	}

	private static int parsePort(String hostPort, String whole) {
		int c = hostPort.lastIndexOf(':');
		String p = c >= 0 ? hostPort.substring(c + 1) : hostPort;
		int semi = p.indexOf(';');
		if (semi >= 0) p = p.substring(0, semi);
		try {
			return Integer.parseInt(p.trim());
		} catch (NumberFormatException e) {
			throw new IllegalArgumentException("bad port: " + whole);
		}
	}

	private static Connection openSocket(String target, int mode) throws IOException {
		String rest = afterSlashes(target);
		int c = rest.lastIndexOf(':');
		if (c < 0) throw new IllegalArgumentException("port missing: " + target);
		int port = parsePort(rest, target);
		if (c == 0) return new TcpServerConnection(port);    // socket://:1234 is a server
		return new TcpConnection(rest.substring(0, c), port, mode);
	}

	private static Connection openDatagram(String target) throws IOException {
		String rest = afterSlashes(target);
		int c = rest.lastIndexOf(':');
		if (c < 0) throw new IllegalArgumentException("port missing: " + target);
		int port = parsePort(rest, target);
		return new UdpConnection(c == 0 ? null : rest.substring(0, c), port);
	}

	private static Connection openRuntimeProtocol(String protocol, String target, int mode, boolean timeouts)
			throws IOException {
		try {
			Class<?> c = Class.forName("org.mini.net." + protocol + ".Protocol");
			com.sun.cldc.io.ConnectionBaseInterface base = (com.sun.cldc.io.ConnectionBaseInterface) c.newInstance();
			return base.openPrim(target, mode, timeouts);
		} catch (InstantiationException e) {
			throw new IOException(e.toString());
		} catch (IllegalAccessException e) {
			throw new IOException(e.toString());
		} catch (ClassNotFoundException e) {
			throw new ConnectionNotFoundException("protocol not supported: " + protocol);
		}
	}

	public static DataInputStream openDataInputStream(String name) throws IOException {
		InputConnection c = openInput(name);
		try {
			return c.openDataInputStream();
		} finally {
			c.close();
		}
	}

	public static DataOutputStream openDataOutputStream(String name) throws IOException {
		OutputConnection c = openOutput(name);
		try {
			return c.openDataOutputStream();
		} finally {
			c.close();
		}
	}

	public static InputStream openInputStream(String name) throws IOException {
		InputConnection c = openInput(name);
		try {
			return c.openInputStream();
		} finally {
			c.close();
		}
	}

	public static OutputStream openOutputStream(String name) throws IOException {
		OutputConnection c = openOutput(name);
		try {
			return c.openOutputStream();
		} finally {
			c.close();
		}
	}

	private static InputConnection openInput(String name) throws IOException {
		Connection c = open(name, READ);
		if (!(c instanceof InputConnection)) {
			c.close();
			throw new IllegalArgumentException("connection cannot be read: " + name);
		}
		return (InputConnection) c;
	}

	private static OutputConnection openOutput(String name) throws IOException {
		Connection c = open(name, WRITE);
		if (!(c instanceof OutputConnection)) {
			c.close();
			throw new IllegalArgumentException("connection cannot be written: " + name);
		}
		return (OutputConnection) c;
	}
}
