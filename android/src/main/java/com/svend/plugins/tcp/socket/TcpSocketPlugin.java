package com.svend.plugins.tcp.socket;

import android.Manifest;
import android.util.Base64;
import android.util.Log;
import android.webkit.WebView;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.WebViewListener;
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
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

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
        /**
         * Runs this socket's writes one at a time, in call order, off the thread serving JS
         * calls. One thread at most, and only while there is something to write.
         */
        final ThreadPoolExecutor writer = new ThreadPoolExecutor(
            0,
            1,
            30,
            TimeUnit.SECONDS,
            new LinkedBlockingQueue<>(),
            daemon("tcp-socket-write")
        );

        Client(Socket socket) {
            this.socket = socket;
        }
    }

    private static ThreadFactory daemon(String name) {
        return (runnable) -> {
            Thread thread = new Thread(runnable, name);
            thread.setDaemon(true);
            return thread;
        };
    }

    /** Pause after the first failed accept(); doubled on each failure in a row, up to the max. */
    private static final long ACCEPT_RETRY_DELAY_MS = 200;
    private static final long ACCEPT_RETRY_MAX_DELAY_MS = 5_000;
    /** A listener whose accept() keeps failing for this long is broken for good and is closed. */
    private static final long ACCEPT_GIVE_UP_MS = 60_000;
    /** Longest timeout in seconds that still fits in connect()'s int milliseconds. */
    private static final int MAX_TIMEOUT_SECONDS = Integer.MAX_VALUE / 1000;

    /** `code` of a rejection, the same on every platform: TcpSocketErrorCode in definitions.ts. */
    private static final String ERR_INVALID_ARGUMENT = "INVALID_ARGUMENT";
    private static final String ERR_CLOSED = "CLOSED";
    private static final String ERR_TIMEOUT = "TIMEOUT";
    private static final String ERR_CONNECT_FAILED = "CONNECT_FAILED";
    private static final String ERR_LISTEN_FAILED = "LISTEN_FAILED";
    private static final String ERR_IO_ERROR = "IO_ERROR";

    /**
     * Stand-in for a closed client: its slot keeps answering "Socket closed" (and disconnect
     * stays idempotent) without holding on to the real socket for the rest of the app's life.
     */
    private static final Client CLOSED = closedClient();

    private static Client closedClient() {
        Socket socket = new Socket();
        try {
            socket.close();
        } catch (IOException ignored) {
            // an unconnected socket has nothing to fail on
        }
        return new Client(socket);
    }

    /**
     * Client ids are indexes into this pool. The accept thread and connect threads append
     * while JS keeps calling send/read, and a closed client keeps its slot (as {@link #CLOSED})
     * so ids stay stable and are never reused. Every compound access (add + index, bounds
     * check + get) happens under the list's lock — a synchronizedList would only make the
     * single operations atomic.
     */
    private final List<Client> clients = new ArrayList<>();
    private final List<ServerSocket> servers = new ArrayList<>();

    /**
     * Bumped by {@link #closeAll()} (under the pool's lock): a connect or accept that started for
     * an earlier page closes its socket instead of adding it to the pool.
     */
    private int generation;

    /**
     * "connection" events that found no listener, delivered to the first one (guarded by the
     * pool's lock). Kept here rather than retained by Capacitor, which has no way to drop them:
     * a page reload must not hand the new page clients of the old one.
     */
    private final List<JSObject> pendingConnections = new ArrayList<>();

    /** Fires send timeouts; created on the first send that asks for one, shut down with the plugin. */
    private ScheduledThreadPoolExecutor sendWatchdog;

    @Override
    public void load() {
        // The bridge drops every event listener when the WebView starts a new page (reload, live
        // update). Sockets the old page opened would outlive it unreachable: their ids are lost,
        // a listening one keeps its port. Close them all with the page that owned them.
        //
        // Registered on the next main-loop turn, not here: Bridge.Builder.create() constructs the
        // bridge (plugins load inside the constructor) and only then calls setWebViewListeners(),
        // which replaces the whole list — a listener added in load() is silently dropped
        // (Capacitor 8.5). listen() also closes its own stale server on the port, in case this
        // hook is ever lost again.
        bridge.executeOnMainThread(() ->
            bridge.addWebViewListener(
                new WebViewListener() {
                    @Override
                    public void onPageStarted(WebView webView) {
                        closeAll();
                    }
                }
            )
        );
    }

    @Override
    protected void handleOnDestroy() {
        closeAll();
        synchronized (this) {
            if (sendWatchdog != null) {
                sendWatchdog.shutdownNow();
            }
        }
    }

    /**
     * Closes every client and server, with no events: the page they belonged to is gone. Ids
     * are not reused, so a stale one from the old page answers "Socket closed".
     */
    private void closeAll() {
        List<Client> open = new ArrayList<>();
        synchronized (clients) {
            generation++;
            pendingConnections.clear();
            for (int i = 0; i < clients.size(); i++) {
                if (clients.get(i) != CLOSED) {
                    open.add(clients.get(i));
                    clients.set(i, CLOSED);
                }
            }
        }
        for (Client client : open) {
            synchronized (client) {
                try {
                    client.socket.close();
                } catch (IOException ignored) {
                    // the socket is unusable either way
                }
            }
        }
        synchronized (servers) {
            for (ServerSocket server : servers) {
                try {
                    server.close();
                } catch (IOException ignored) {
                    // closing is best effort
                }
            }
        }
    }

    private int currentGeneration() {
        synchronized (clients) {
            return generation;
        }
    }

    /** Caller holds the pool's lock. Returns the new id, or -1 (socket closed) for a stale page. */
    private int addClientLocked(Socket socket, int pageGeneration) {
        if (pageGeneration != generation) {
            try {
                socket.close();
            } catch (IOException ignored) {
                // nobody is left to use it either way
            }
            return -1;
        }
        clients.add(new Client(socket));
        return clients.size() - 1;
    }

    @Override
    @PluginMethod(returnType = PluginMethod.RETURN_NONE)
    public void addListener(PluginCall call) {
        super.addListener(call);
        if ("connection".equals(call.getString("eventName"))) {
            synchronized (clients) {
                for (JSObject event : pendingConnections) {
                    notifyListeners("connection", event);
                }
                pendingConnections.clear();
            }
        }
    }

    /** Frees the slot of a closed client; in-flight calls keep their own reference to it. */
    private void release(int index, Client client) {
        synchronized (clients) {
            if (index >= 0 && index < clients.size() && clients.get(index) == client) {
                clients.set(index, CLOSED);
            }
        }
    }

    private synchronized ScheduledThreadPoolExecutor sendWatchdog() {
        if (sendWatchdog == null) {
            ScheduledThreadPoolExecutor executor = new ScheduledThreadPoolExecutor(1, daemon("tcp-socket-send-timeout"));
            // A finished send cancels its timeout: drop it at once instead of keeping it queued.
            executor.setRemoveOnCancelPolicy(true);
            sendWatchdog = executor;
        }
        return sendWatchdog;
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

    private void closeServersOnPort(int port) {
        synchronized (servers) {
            for (ServerSocket server : servers) {
                if (!server.isClosed() && server.getLocalPort() == port) {
                    try {
                        server.close();
                    } catch (IOException ignored) {
                        // closing is best effort; the bind below reports a real conflict
                    }
                }
            }
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
        release(clientIndex, client);
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
            call.reject("Must provide ip address to connect", ERR_INVALID_ARGUMENT);
            return;
        }
        final int port = call.getInt("port", 9100);
        // Seconds; 0 = no limit. Clamped so the milliseconds below cannot overflow.
        final int timeout = Math.min(Math.max(0, call.getInt("timeout", 10)), MAX_TIMEOUT_SECONDS);
        if (port < 0 || port > 65535) {
            call.reject("Port out of range: " + port, ERR_INVALID_ARGUMENT);
            return;
        }

        // connect() blocks up to `timeout` on an unreachable address, and the thread serving JS
        // calls is shared by every plugin: run here, it would stall printing, reads and sends
        // to live peers until it gives up. Ids are handed out under the pool lock, so connects
        // finishing on several threads at once still get distinct ids.
        final int pageGeneration = currentGeneration();
        new Thread(() -> {
            Socket socket = new Socket();
            try {
                socket.connect(new InetSocketAddress(ipAddress, port), timeout * 1000);
            } catch (IOException | RuntimeException e) {
                Log.d("Connection failed", String.valueOf(e.getMessage()));
                try {
                    socket.close();
                } catch (IOException ignored) {
                    // nothing was opened that could leak
                }
                call.reject(e.getMessage(), ERR_CONNECT_FAILED);
                return;
            }

            final int clientIndex;
            synchronized (clients) {
                clientIndex = addClientLocked(socket, pageGeneration);
            }
            if (clientIndex == -1) {
                // The page reloaded while connecting: nobody is left to use this socket.
                call.reject("Socket closed", ERR_CLOSED);
                return;
            }
            JSObject ret = new JSObject();
            ret.put("client", clientIndex);
            call.resolve(ret);
        }, "tcp-socket-connect").start();
    }

    @PluginMethod()
    public void send(final PluginCall call) {
        final int clientIndex = call.getInt("client", -1);
        final String msg = call.getString("data", "");
        final int timeout = Math.max(0, call.getInt("timeout", 0)); // seconds; 0 = no limit

        if (clientIndex == -1) {
            call.reject("No client specified", ERR_INVALID_ARGUMENT);
            return;
        }
        final Client client = clientAt(clientIndex);
        if (client == null) {
            call.reject("Invalid client index", ERR_INVALID_ARGUMENT);
            return;
        }
        if (client.socket.isClosed()) {
            call.reject("Socket closed", ERR_CLOSED);
            return;
        }
        final byte[] decoded;
        try {
            decoded = Base64.decode(msg, Base64.DEFAULT);
        } catch (IllegalArgumentException e) {
            call.reject("Invalid base64 data", ERR_INVALID_ARGUMENT);
            return;
        }

        // Settled once: by the write, or by the timeout — whichever comes first.
        final AtomicBoolean settled = new AtomicBoolean(false);
        // write() has no timeout of its own: it blocks for as long as the peer does not read
        // and the buffers stay full. Closing the socket is the only way to free it. Counted from
        // the call, so a send queued behind a stuck one still times out — and frees both.
        final ScheduledFuture<?> watchdog;
        try {
            watchdog =
                timeout == 0
                    ? null
                    : sendWatchdog().schedule(
                          () -> {
                              if (settled.compareAndSet(false, true)) {
                                  peerGone(clientIndex, client);
                                  call.reject("Send timed out", ERR_TIMEOUT);
                              }
                          },
                          timeout,
                          TimeUnit.SECONDS
                      );
        } catch (RejectedExecutionException e) {
            // handleOnDestroy shut the watchdog down: the plugin is going away.
            call.reject("Plugin released", ERR_CLOSED);
            return;
        }

        // write() blocks when the peer stops reading, so it runs off the thread serving JS calls;
        // the client's writer keeps sends in call order and never interleaves their bytes.
        try {
            client.writer.execute(() -> {
                if (settled.get()) {
                    // Timed out while queued: the socket is closed already.
                    return;
                }
                try {
                    OutputStream out = client.socket.getOutputStream();
                    out.write(decoded);
                    out.flush();
                    if (settled.compareAndSet(false, true)) {
                        if (watchdog != null) {
                            watchdog.cancel(false);
                        }
                        call.resolve();
                    }
                } catch (IOException e) {
                    if (!settled.compareAndSet(false, true)) {
                        // The timeout closed the socket under this write and has rejected the call.
                        return;
                    }
                    if (watchdog != null) {
                        watchdog.cancel(false);
                    }
                    if (client.socket.isClosed()) {
                        call.reject("Socket closed", ERR_CLOSED);
                    } else {
                        // Broken pipe / connection reset: the peer is gone.
                        peerGone(clientIndex, client);
                        call.reject(e.getMessage(), ERR_IO_ERROR);
                    }
                }
            });
        } catch (RejectedExecutionException e) {
            // Out of threads: nothing was written, and this client cannot send any more.
            // Closed like a dropped connection, as IO_ERROR promises.
            if (settled.compareAndSet(false, true)) {
                if (watchdog != null) {
                    watchdog.cancel(false);
                }
                peerGone(clientIndex, client);
                call.reject(String.valueOf(e.getMessage()), ERR_IO_ERROR);
            }
        }
    }

    @PluginMethod()
    public void read(final PluginCall call) {
        final int clientIndex = call.getInt("client", -1);
        final int length = call.getInt("expectLen", 1024);
        // Seconds; 0 = only what is already there. Clamped so the milliseconds below cannot overflow.
        final int timeout = Math.min(Math.max(0, call.getInt("timeout", 10)), MAX_TIMEOUT_SECONDS);

        if (clientIndex == -1 || length <= 0) {
            call.reject("Client or length not specified", ERR_INVALID_ARGUMENT);
            return;
        }
        final Client client = clientAt(clientIndex);
        if (client == null) {
            call.reject("Invalid client index", ERR_INVALID_ARGUMENT);
            return;
        }
        if (client.socket.isClosed()) {
            call.reject("Socket closed", ERR_CLOSED);
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
                    call.reject("Socket closed", ERR_CLOSED);
                } else {
                    peerGone(clientIndex, client);
                    call.reject(e.getMessage(), ERR_IO_ERROR);
                }
            }
        }).start();
    }

    @PluginMethod()
    public void disconnect(PluginCall call) {
        final int clientIndex = call.getInt("client", -1);
        if (clientIndex == -1) {
            call.reject("No client specified", ERR_INVALID_ARGUMENT);
            return;
        }
        final Client client = clientAt(clientIndex);
        if (client == null) {
            call.reject("Invalid client index", ERR_INVALID_ARGUMENT);
            return;
        }
        synchronized (client) {
            try {
                // Idempotent: closing a closed socket is a no-op. A blocked read on this
                // socket gets "Socket closed" from its own thread.
                client.socket.close();
            } catch (IOException ignored) {
                // the socket is unusable either way, and its slot is released below
            }
        }
        release(clientIndex, client);

        JSObject ret = new JSObject();
        ret.put("client", clientIndex);
        call.resolve(ret);
    }

    @PluginMethod()
    public void listen(PluginCall call) {
        final int port = call.getInt("port", 9100);
        if (port < 0 || port > 65535) {
            call.reject("Port out of range: " + port, ERR_INVALID_ARGUMENT);
            return;
        }

        // A server this plugin still holds on the port belongs to a page that is gone (its JS
        // lost the id) or to a listen() that was never stopped — either way nobody can reach it,
        // and it would only make this bind fail with EADDRINUSE.
        closeServersOnPort(port);
        final ServerSocket server;
        try {
            server = new ServerSocket(port);
        } catch (IOException e) {
            call.reject(e.getMessage(), ERR_LISTEN_FAILED);
            return;
        }
        final int serverIndex = addServer(server);
        final int pageGeneration = currentGeneration();

        // accept() blocks until a peer arrives, so the loop cannot run on the
        // thread serving JS calls.
        new Thread(() -> {
            long delay = ACCEPT_RETRY_DELAY_MS;
            long failingSince = 0;
            while (!server.isClosed()) {
                final Socket accepted;
                try {
                    accepted = server.accept();
                    delay = ACCEPT_RETRY_DELAY_MS;
                    failingSince = 0;
                } catch (IOException e) {
                    // A close may wake the accept before the socket reports itself closed, so
                    // look again after the pause before taking this for a failure.
                    if (!server.isClosed()) {
                        try {
                            Thread.sleep(delay);
                        } catch (InterruptedException interrupted) {
                            return;
                        }
                    }
                    if (server.isClosed()) {
                        // stopListening (or a page reload) closed the socket: the only way this
                        // loop ends, but for the one below.
                        return;
                    }
                    // A failed accept (aborted handshake, out of descriptors, the network
                    // changing under the socket) says nothing about the next one: giving up at
                    // once would leave the app believing it still listens. Back off instead, and
                    // only a listener that fails for a whole minute is taken for broken.
                    long now = System.currentTimeMillis();
                    if (failingSince == 0) {
                        failingSince = now;
                        Log.w("TcpSocket", "accept failed, retrying: " + e.getMessage());
                    } else if (now - failingSince >= ACCEPT_GIVE_UP_MS) {
                        Log.e("TcpSocket", "accept keeps failing, closing the listener: " + e.getMessage());
                        try {
                            server.close();
                        } catch (IOException ignored) {
                            // closing is best effort
                        }
                        return;
                    }
                    delay = Math.min(delay * 2, ACCEPT_RETRY_MAX_DELAY_MS);
                    continue;
                }
                synchronized (clients) {
                    int clientIndex = addClientLocked(accepted, pageGeneration);
                    if (clientIndex == -1) {
                        // Accepted just as the page reloaded: closeAll closes the server next.
                        return;
                    }
                    JSObject event = new JSObject();
                    event.put("server", serverIndex);
                    event.put("client", clientIndex);
                    event.put("address", accepted.getInetAddress().getHostAddress());
                    // Kept until a listener comes: a peer may connect before JS has attached
                    // one, and the client would otherwise be unreachable from JS. Behind
                    // events still pending, so they arrive in order.
                    if (pendingConnections.isEmpty() && hasListeners("connection")) {
                        notifyListeners("connection", event);
                    } else {
                        pendingConnections.add(event);
                    }
                }
            }
        }, "tcp-socket-accept-" + serverIndex).start();

        JSObject ret = new JSObject();
        ret.put("server", serverIndex);
        ret.put("port", server.getLocalPort());
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
            call.reject("No server specified", ERR_INVALID_ARGUMENT);
            return;
        }
        final ServerSocket server = serverAt(serverIndex);
        if (server == null) {
            call.reject("Invalid server index", ERR_INVALID_ARGUMENT);
            return;
        }

        try {
            // Closing the socket is what ends the accept loop: it makes the
            // pending accept() throw, and the thread returns.
            server.close();
        } catch (IOException ignored) {
            // closing is best effort, as in closeAll(): the accept loop ends either way
        }
        call.resolve();
    }
}
