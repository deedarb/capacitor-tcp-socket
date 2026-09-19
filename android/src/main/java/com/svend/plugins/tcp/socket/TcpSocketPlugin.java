package com.svend.plugins.tcp.socket;

import android.Manifest;
import android.util.Base64;
import android.util.Log;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

@CapacitorPlugin(
    name = "TcpSocket",
    permissions = { @Permission(alias = "network", strings = { Manifest.permission.ACCESS_NETWORK_STATE }) }
)
public class TcpSocketPlugin extends Plugin {

    /** A pooled connection: one from connect() or one accepted by a listening socket. */
    private static final class Client {

        final Socket socket;
        /**
         * Serialises reads on this socket: two concurrent reads would split one message
         * between them. Never held while closing, so a blocked read cannot deadlock a close.
         */
        final Object readLock = new Object();

        Client(Socket socket) {
            this.socket = socket;
        }
    }

    /**
     * Client ids are indexes into this pool. The accept thread appends while JS keeps
     * calling send/read, and a closed client keeps its slot so ids stay stable. Every
     * compound access (add + index, bounds check + get) happens under the list's lock —
     * a synchronizedList would only make the single operations atomic.
     */
    private final List<Client> clients = new ArrayList<>();
    private final List<ServerSocket> servers = new ArrayList<>();

    private int addClient(Socket socket) {
        synchronized (clients) {
            clients.add(new Client(socket));
            return clients.size() - 1;
        }
    }

    private Client clientAt(int index) {
        synchronized (clients) {
            return index >= 0 && index < clients.size() ? clients.get(index) : null;
        }
    }

    private int addServer(ServerSocket server) {
        synchronized (servers) {
            servers.add(server);
            return servers.size() - 1;
        }
    }

    private ServerSocket serverAt(int index) {
        synchronized (servers) {
            return index >= 0 && index < servers.size() ? servers.get(index) : null;
        }
    }

    /**
     * Closes the client and tells JS the peer is gone — once: only the close that actually
     * closes the socket emits the event, and a local disconnect() is not a peer event.
     */
    private void peerGone(int clientIndex, Client client) {
        boolean wasOpen;
        synchronized (client) {
            wasOpen = !client.socket.isClosed();
            if (wasOpen) {
                try {
                    client.socket.close();
                } catch (IOException ignored) {
                    // the socket is unusable either way
                }
            }
        }
        if (wasOpen) {
            JSObject event = new JSObject();
            event.put("client", clientIndex);
            notifyListeners("disconnection", event);
        }
    }

    private static void resolveResult(PluginCall call, String result) {
        JSObject ret = new JSObject();
        ret.put("result", result);
        call.resolve(ret);
    }

    @PluginMethod()
    public void connect(PluginCall call) {
        String ipAddress = call.getString("ipAddress");

        if (ipAddress == null || ipAddress.isEmpty()) {
            call.reject("Must provide ip address to connect");
            return;
        }
        int port = call.getInt("port", 9100);
        int timeout = call.getInt("timeout", 10); // seconds

        Socket socket = new Socket();
        try {
            socket.connect(new InetSocketAddress(ipAddress, port), timeout * 1000);
        } catch (IOException e) {
            Log.d("Connection failed", String.valueOf(e.getMessage()));
            call.reject(e.getMessage());
            return;
        }

        JSObject ret = new JSObject();
        ret.put("client", addClient(socket));
        call.resolve(ret);
    }

    @PluginMethod()
    public void send(final PluginCall call) {
        final int clientIndex = call.getInt("client", -1);
        final String msg = call.getString("data", "");

        if (clientIndex == -1) {
            call.reject("No client specified");
            return;
        }
        final Client client = clientAt(clientIndex);
        if (client == null) {
            call.reject("Invalid client index");
            return;
        }
        if (client.socket.isClosed()) {
            call.reject("Socket closed");
            return;
        }
        final byte[] decoded;
        try {
            decoded = Base64.decode(msg, Base64.DEFAULT);
        } catch (IllegalArgumentException e) {
            call.reject("Invalid base64 data");
            return;
        }

        // write() blocks when the peer stops reading, so it runs off the thread serving JS calls.
        new Thread(() -> {
            try {
                OutputStream out = client.socket.getOutputStream();
                out.write(decoded);
                out.flush();
                call.resolve();
            } catch (IOException e) {
                if (client.socket.isClosed()) {
                    call.reject("Socket closed");
                } else {
                    // Broken pipe / connection reset: the peer is gone.
                    peerGone(clientIndex, client);
                    call.reject(e.getMessage());
                }
            }
        }).start();
    }

    @PluginMethod()
    public void read(final PluginCall call) {
        final int clientIndex = call.getInt("client", -1);
        final int length = call.getInt("expectLen", 1024);
        final int timeout = Math.max(0, call.getInt("timeout", 10)); // seconds; 0 = only what is already there

        if (clientIndex == -1 || length <= 0) {
            call.reject("Client or length not specified");
            return;
        }
        final Client client = clientAt(clientIndex);
        if (client == null) {
            call.reject("Invalid client index");
            return;
        }
        if (client.socket.isClosed()) {
            call.reject("Socket closed");
            return;
        }

        // The read blocks up to `timeout`, so it runs off the thread serving JS calls.
        new Thread(() -> {
            try {
                synchronized (client.readLock) {
                    // One recv straight from the socket, no BufferedInputStream: a buffer created per
                    // call could swallow bytes past `length` and lose them for the next read.
                    client.socket.setSoTimeout(timeout * 1000);
                    byte[] bytes = new byte[length];
                    int read = client.socket.getInputStream().read(bytes, 0, length);
                    if (read > 0) {
                        // Raw bytes as base64, same as iOS. NO_WRAP: iOS does not insert line breaks either.
                        resolveResult(call, Base64.encodeToString(bytes, 0, read, Base64.NO_WRAP));
                        return;
                    }
                }
                // End of stream: the peer closed. Report it once; further reads are rejected.
                peerGone(clientIndex, client);
                resolveResult(call, "");
            } catch (SocketTimeoutException e) {
                // Peer connected and went silent: not an error for the caller, just nothing to read.
                resolveResult(call, "");
            } catch (IOException e) {
                if (client.socket.isClosed()) {
                    // disconnect() closed it while we were waiting
                    call.reject("Socket closed");
                } else {
                    peerGone(clientIndex, client);
                    call.reject(e.getMessage());
                }
            }
        }).start();
    }

    @PluginMethod()
    public void disconnect(PluginCall call) {
        final int clientIndex = call.getInt("client", -1);
        if (clientIndex == -1) {
            call.reject("No client specified");
            return;
        }
        final Client client = clientAt(clientIndex);
        if (client == null) {
            call.reject("Invalid client index");
            return;
        }
        synchronized (client) {
            try {
                // Idempotent: closing a closed socket is a no-op. A blocked read on this
                // socket gets "Socket closed" from its own thread.
                client.socket.close();
            } catch (IOException e) {
                call.reject(e.getMessage());
                return;
            }
        }

        JSObject ret = new JSObject();
        ret.put("client", clientIndex);
        call.resolve(ret);
    }

    @PluginMethod()
    public void listen(PluginCall call) {
        final int port = call.getInt("port", 9100);

        final ServerSocket server;
        try {
            server = new ServerSocket(port);
        } catch (IOException e) {
            call.reject(e.getMessage());
            return;
        }
        final int serverIndex = addServer(server);

        // accept() blocks until a peer arrives, so the loop cannot run on the
        // thread serving JS calls.
        new Thread(() -> {
            while (!server.isClosed()) {
                final Socket accepted;
                try {
                    accepted = server.accept();
                } catch (IOException e) {
                    // stopListening closed the socket, or accept failed
                    return;
                }
                JSObject event = new JSObject();
                event.put("server", serverIndex);
                event.put("client", addClient(accepted));
                event.put("address", accepted.getInetAddress().getHostAddress());
                // Retained: a peer may connect before JS has attached its listener,
                // and the client would otherwise be unreachable from JS.
                notifyListeners("connection", event, true);
            }
        }, "tcp-socket-accept-" + serverIndex).start();

        JSObject ret = new JSObject();
        ret.put("server", serverIndex);
        call.resolve(ret);
    }

    /**
     * Address of this device in the local network: Wi-Fi (wlan0) first, IPv4 first. Peers reach the
     * device at this address without internet; the app sends it with heartbeats.
     */
    @PluginMethod()
    public void getLocalAddress(PluginCall call) {
        String bestIp = null;
        String bestName = null;
        int bestScore = -1;
        try {
            for (NetworkInterface iface : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!iface.isUp() || iface.isLoopback()) {
                    continue;
                }
                String name = iface.getName();
                // Cellular (rmnet*) and VPN tunnels (tun*, ppp*) are useless to LAN peers.
                if (name.startsWith("rmnet") || name.startsWith("dummy") || name.startsWith("tun") || name.startsWith("ppp")) {
                    continue;
                }
                for (InetAddress address : Collections.list(iface.getInetAddresses())) {
                    if (address.isLoopbackAddress() || address.isLinkLocalAddress()) {
                        continue;
                    }
                    int score =
                        (name.startsWith("wlan") ? 4 : 0) + (address instanceof Inet4Address ? 2 : 0) + (name.startsWith("eth") ? 1 : 0);
                    if (score > bestScore) {
                        bestScore = score;
                        String ip = address.getHostAddress();
                        int zone = ip == null ? -1 : ip.indexOf('%');
                        bestIp = zone >= 0 ? ip.substring(0, zone) : ip;
                        bestName = name;
                    }
                }
            }
        } catch (Exception e) {
            call.resolve(new JSObject());
            return;
        }
        JSObject result = new JSObject();
        if (bestIp != null) {
            result.put("ip", bestIp);
            result.put("interfaceName", bestName);
        }
        call.resolve(result);
    }

    @PluginMethod()
    public void stopListening(PluginCall call) {
        final int serverIndex = call.getInt("server", -1);
        if (serverIndex == -1) {
            call.reject("No server specified");
            return;
        }
        final ServerSocket server = serverAt(serverIndex);
        if (server == null) {
            call.reject("Invalid server index");
            return;
        }

        try {
            // Closing the socket is what ends the accept loop: it makes the
            // pending accept() throw, and the thread returns.
            server.close();
        } catch (IOException e) {
            call.reject(e.getMessage());
            return;
        }
        call.resolve();
    }
}
