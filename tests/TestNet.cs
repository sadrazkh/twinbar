// Local network stand-ins for tests/smoke.ps1 (C# 5, Windows PowerShell's Add-Type):
// a SOCKS5 proxy and an HTTP CONNECT proxy that relay traffic and log where they
// were asked to go, and a small HTTP server that answers like an IP-address service.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class TestProxy {
  readonly TcpListener listener;
  readonly bool socks;
  readonly List<string> requests = new List<string>();

  public TestProxy(bool socks) {
    this.socks = socks;
    listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    Thread accept = new Thread(Accept);
    accept.IsBackground = true;
    accept.Start();
  }

  public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }

  // Every "host:port" it was asked to connect to, in order.
  public string[] Requests() { lock (requests) return requests.ToArray(); }

  public void Stop() { listener.Stop(); }

  void Accept() {
    while (true) {
      TcpClient client;
      try { client = listener.AcceptTcpClient(); } catch (Exception) { return; }
      Thread worker = new Thread(delegate () { Serve(client); });
      worker.IsBackground = true;
      worker.Start();
    }
  }

  static byte[] ReadExactly(Stream s, int count) {
    byte[] buffer = new byte[count];
    int done = 0;
    while (done < count) {
      int n = s.Read(buffer, done, count - done);
      if (n <= 0) throw new IOException("closed");
      done += n;
    }
    return buffer;
  }

  static string ReadLine(Stream s) {
    StringBuilder line = new StringBuilder();
    while (true) {
      int b = s.ReadByte();
      if (b < 0) throw new IOException("closed");
      if (b == '\n') return line.ToString().TrimEnd('\r');
      line.Append((char)b);
    }
  }

  void Serve(TcpClient client) {
    TcpClient upstream = null;
    try {
      NetworkStream s = client.GetStream();
      string host;
      int port;
      if (socks) {
        byte[] hello = ReadExactly(s, 2);
        ReadExactly(s, hello[1]);
        s.Write(new byte[] { 5, 0 }, 0, 2);
        byte[] request = ReadExactly(s, 4);
        if (request[3] == 3) host = Encoding.ASCII.GetString(ReadExactly(s, ReadExactly(s, 1)[0]));
        else if (request[3] == 1) host = new IPAddress(ReadExactly(s, 4)).ToString();
        else host = new IPAddress(ReadExactly(s, 16)).ToString();
        byte[] p = ReadExactly(s, 2);
        port = p[0] * 256 + p[1];
      } else {
        string first = ReadLine(s);
        while (ReadLine(s).Length > 0) { }
        string[] parts = first.Split(' ');
        string target = parts.Length > 1 ? parts[1] : "";
        if (parts[0] != "CONNECT") {
          lock (requests) requests.Add(target);
          byte[] refuse = Encoding.ASCII.GetBytes("HTTP/1.1 502 Only CONNECT here\r\n\r\n");
          s.Write(refuse, 0, refuse.Length);
          return;
        }
        int colon = target.LastIndexOf(':');
        host = target.Substring(0, colon);
        port = int.Parse(target.Substring(colon + 1));
      }
      lock (requests) requests.Add(host + ":" + port);
      upstream = new TcpClient();
      try {
        upstream.Connect(host.Trim('[', ']'), port);
      } catch (Exception) {
        byte[] fail = socks ? new byte[] { 5, 4, 0, 1, 0, 0, 0, 0, 0, 0 } : Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\n\r\n");
        s.Write(fail, 0, fail.Length);
        return;
      }
      byte[] ok = socks ? new byte[] { 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 } : Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n");
      s.Write(ok, 0, ok.Length);
      NetworkStream u = upstream.GetStream();
      TcpClient up = upstream;
      Thread back = new Thread(delegate () { Pipe(u, s, client, up); });
      back.IsBackground = true;
      back.Start();
      Pipe(s, u, client, upstream);
      upstream = null;
    } catch (Exception) {
      // A test proxy: a broken connection just ends.
    } finally {
      if (upstream != null) upstream.Close();
    }
  }

  static void Pipe(Stream from, Stream to, TcpClient a, TcpClient b) {
    byte[] buffer = new byte[16384];
    try {
      int n;
      while ((n = from.Read(buffer, 0, buffer.Length)) > 0) to.Write(buffer, 0, n);
    } catch (Exception) {
    } finally {
      a.Close();
      b.Close();
    }
  }
}

// Answers every request with the same JSON, like ipinfo.io does.
public class TestIpService {
  readonly TcpListener listener;
  readonly string json;
  int hits;

  public TestIpService(string json) {
    this.json = json;
    listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    Thread accept = new Thread(Accept);
    accept.IsBackground = true;
    accept.Start();
  }

  public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
  public int Hits { get { return hits; } }
  public void Stop() { listener.Stop(); }

  void Accept() {
    while (true) {
      TcpClient client;
      try { client = listener.AcceptTcpClient(); } catch (Exception) { return; }
      try {
        NetworkStream s = client.GetStream();
        StringBuilder head = new StringBuilder();
        while (!head.ToString().EndsWith("\r\n\r\n")) {
          int b = s.ReadByte();
          if (b < 0) break;
          head.Append((char)b);
        }
        Interlocked.Increment(ref hits);
        byte[] body = Encoding.UTF8.GetBytes(json);
        byte[] answer = Encoding.ASCII.GetBytes("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.Length + "\r\n\r\n");
        s.Write(answer, 0, answer.Length);
        s.Write(body, 0, body.Length);
      } catch (Exception) {
      } finally {
        client.Close();
      }
    }
  }
}

// Serves fixed files and redirects over HTTP/1.1, as GitHub's API and release
// downloads do, and logs the paths it was asked for.
public class TestWebServer {
  readonly TcpListener listener;
  readonly Dictionary<string, byte[]> files = new Dictionary<string, byte[]>();
  readonly Dictionary<string, string> redirects = new Dictionary<string, string>();
  readonly List<string> requests = new List<string>();

  public TestWebServer() {
    listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    Thread accept = new Thread(Accept);
    accept.IsBackground = true;
    accept.Start();
  }

  public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
  public string Url(string path) { return "http://127.0.0.1:" + Port + path; }
  public void Put(string path, byte[] body) { lock (files) files[path] = body; }
  public void PutText(string path, string text) { Put(path, Encoding.UTF8.GetBytes(text)); }
  public void Redirect(string path, string to) { lock (files) redirects[path] = to; }
  public string[] Requests() { lock (requests) return requests.ToArray(); }
  public void Stop() { listener.Stop(); }

  void Accept() {
    while (true) {
      TcpClient client;
      try { client = listener.AcceptTcpClient(); } catch (Exception) { return; }
      Thread worker = new Thread(delegate () { Serve(client); });
      worker.IsBackground = true;
      worker.Start();
    }
  }

  void Serve(TcpClient client) {
    try {
      NetworkStream s = client.GetStream();
      StringBuilder head = new StringBuilder();
      while (!head.ToString().EndsWith("\r\n\r\n")) {
        int b = s.ReadByte();
        if (b < 0) return;
        head.Append((char)b);
      }
      string[] first = head.ToString().Split(' ');
      string path = first.Length > 1 ? first[1] : "/";
      lock (requests) requests.Add(path);
      byte[] body;
      string location;
      lock (files) {
        files.TryGetValue(path, out body);
        redirects.TryGetValue(path, out location);
      }
      string status = location != null ? "302 Found" : body != null ? "200 OK" : "404 Not Found";
      if (body == null) body = new byte[0];
      string headers = "HTTP/1.1 " + status + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n" +
        (location != null ? "Location: " + location + "\r\n" : "") + "\r\n";
      byte[] h = Encoding.ASCII.GetBytes(headers);
      s.Write(h, 0, h.Length);
      s.Write(body, 0, body.Length);
    } catch (Exception) {
    } finally {
      client.Close();
    }
  }
}
