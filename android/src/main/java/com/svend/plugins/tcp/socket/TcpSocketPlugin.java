package com.svend.plugins.tcp.socket;

import android.Manifest;
import android.os.Build;
import android.util.Log;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.List;

@CapacitorPlugin(
    name = "TcpSocket",
    permissions = { @Permission(alias = "network", strings = { Manifest.permission.ACCESS_NETWORK_STATE }) }
)
public class TcpSocketPlugin extends Plugin {

    private Socket socket;
    private DataOutputStream mBufferOut;
    /**
     * Synchronized: with a listening socket this list is also appended to from
     * the accept thread, while JS keeps calling send/read on the main thread.
     */
    private final List<Socket> clients = Collections.synchronizedList(new ArrayList<>());
    private final List<ServerSocket> servers = Collections.synchronizedList(new ArrayList<>());

    @PluginMethod()
    public void connect(PluginCall call) {
        String ipAddress = call.getString("ipAddress");

        if (ipAddress == null || ipAddress.isEmpty()) {
            call.reject("Must provide ip address to connect");
            return;
        }
        Integer port = call.getInt("port", 9100);
        Integer timeout = call.getInt("timeout", 10); // Default 10 second timeout (in seconds)

        try {
            if (socket != null && socket.isConnected()) {
                socket.close();
            }
            socket = new Socket();
            socket.connect(new InetSocketAddress(ipAddress, port), timeout * 1000); // Convert seconds to milliseconds
            clients.add(socket);
        } catch (IOException e) {
            Log.d("Connection failed", e.getMessage());
            call.reject(e.getMessage());
            return;
        }

        JSObject ret = new JSObject();
        ret.put("client", clients.size() - 1);
        call.resolve(ret);
    }

    @PluginMethod()
    public void send(final PluginCall call) {
        final Integer client = call.getInt("client", -1);
        final String msg = call.getString("data", "");

        if (client == -1) {
            call.reject("No client specified");
            return;
        }

        Runnable runnable = () -> {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    final Socket socket = clients.get(client);
                    mBufferOut = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));
                    byte[] decoded = Base64.getDecoder().decode(msg);
                    if (mBufferOut != null) {
                        mBufferOut.write(decoded);
                        mBufferOut.flush();
                    }
                }
                call.resolve();
            } catch (IOException e) {
                call.reject(e.getMessage());
            }
        };

        Socket socket = clients.get(client);
        if (!socket.isConnected()) {
            try {
                socket.close();
            } catch (IOException e) {
                call.reject("Generic error");
            }
            call.reject("Socket not connected");
            return;
        }
        Thread thread = new Thread(runnable);
        thread.start();
    }

    @PluginMethod()
    public void read(final PluginCall call) {
        final Integer client = call.getInt("client", -1);
        final Integer length = call.getInt("expectLen", 1024);

        if (client == -1 || length == -1) {
            call.reject("Client or length not specified");
            return;
        }

        Runnable runnable = () -> {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    final Socket socket = clients.get(client);
                    DataInputStream mBufferIn = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
                    byte[] bytes = new byte[length];
                    int read = mBufferIn.read(bytes, 0, length);
                    Base64.getEncoder().encodeToString(bytes);
                    JSObject ret = new JSObject();
                    ret.put("result", new String(bytes, 0, read));
                    call.resolve(ret);
                } else {
                    JSObject ret = new JSObject();
                    ret.put("result", "");
                    call.resolve(ret);
                }
            } catch (IOException e) {
                call.reject(e.getMessage());
            }
        };

        Socket socket = clients.get(client);
        if (!socket.isConnected()) {
            try {
                socket.close();
            } catch (IOException e) {
                call.reject("Generic error");
            }
            call.reject("Socket not connected");
            return;
        }
        Thread thread = new Thread(runnable);
        thread.start();
    }

    @PluginMethod()
    public void disconnect(PluginCall call) {
        final Integer client = call.getInt("client", -1);
        if (client == -1) {
            call.reject("No client specified");
            return;
        }
        if (clients.isEmpty()) {
            call.reject("Socket not connected");
            return;
        }
        final Socket socket = clients.get(client);
        try {
            if (!socket.isConnected()) {
                socket.close();
                call.reject("Socket not connected");
            }
            socket.close();
        } catch (IOException e) {
            call.reject(e.getMessage());
        }

        JSObject ret = new JSObject();
        ret.put("client", client);
        call.resolve(ret);
    }

    @PluginMethod()
    public void listen(PluginCall call) {
        final Integer port = call.getInt("port", 9100);

        final ServerSocket server;
        try {
            server = new ServerSocket(port);
        } catch (IOException e) {
            call.reject(e.getMessage());
            return;
        }
        servers.add(server);
        final int serverIndex = servers.size() - 1;

        // accept() blocks until a peer arrives, so the loop cannot run on the
        // thread serving JS calls.
        new Thread(() -> {
            while (!server.isClosed()) {
                try {
                    Socket accepted = server.accept();
                    clients.add(accepted);
                    JSObject event = new JSObject();
                    event.put("server", serverIndex);
                    event.put("client", clients.size() - 1);
                    event.put("address", accepted.getInetAddress().getHostAddress());
                    notifyListeners("connection", event);
                } catch (IOException e) {
                    // stopListening closed the socket, or accept failed
                    return;
                }
            }
        }).start();

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
                // Cellular (rmnet*) is useless to peers; Wi-Fi first, then ethernet/others.
                if (name.startsWith("rmnet") || name.startsWith("dummy")) {
                    continue;
                }
                for (InetAddress address : Collections.list(iface.getInetAddresses())) {
                    if (address.isLoopbackAddress() || address.isLinkLocalAddress()) {
                        continue;
                    }
                    int score = (name.startsWith("wlan") ? 4 : 0) + (address instanceof Inet4Address ? 2 : 0) + (name.startsWith("eth") ? 1 : 0);
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
        final Integer server = call.getInt("server", -1);
        if (server == -1) {
            call.reject("No server specified");
            return;
        }
        if (server < 0 || server >= servers.size()) {
            call.reject("Invalid server index");
            return;
        }

        try {
            // Closing the socket is what ends the accept loop: it makes the
            // pending accept() throw, and the thread returns.
            servers.get(server).close();
        } catch (IOException e) {
            call.reject(e.getMessage());
            return;
        }
        call.resolve();
    }
}
