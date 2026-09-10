# WSL2 only publishes forwarded ports on Windows IPv6 (::1 / localhost).
# Docker Desktop and http://127.0.0.1 use IPv4, so they miss the host app.
# This process listens on 0.0.0.0:<port> and relays to [::1]:<port>.
param(
    [int]$Port = 18080
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;

public static class WslIpv4Proxy {
    public static void Run(int port) {
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        listener.Start();
        while (true) {
            var client = listener.AcceptTcpClient();
            ThreadPool.QueueUserWorkItem(_ => Handle(client, port));
        }
    }

    static void Handle(TcpClient client, int port) {
        TcpClient dest = null;
        try {
            dest = new TcpClient(AddressFamily.InterNetworkV6);
            dest.Client.DualMode = true;
            dest.Connect(IPAddress.IPv6Loopback, port);
            var a = client.GetStream();
            var b = dest.GetStream();
            var t1 = new Thread(() => Copy(a, b));
            var t2 = new Thread(() => Copy(b, a));
            t1.IsBackground = true;
            t2.IsBackground = true;
            t1.Start();
            t2.Start();
            t1.Join();
            t2.Join();
        } catch {
        } finally {
            try { client.Close(); } catch {}
            try { if (dest != null) dest.Close(); } catch {}
        }
    }

    static void Copy(NetworkStream from, NetworkStream to) {
        var buf = new byte[8192];
        try {
            int n;
            while ((n = from.Read(buf, 0, buf.Length)) > 0) {
                to.Write(buf, 0, n);
            }
        } catch {
        }
        try { to.Close(); } catch {}
    }
}
"@

[WslIpv4Proxy]::Run($Port)
