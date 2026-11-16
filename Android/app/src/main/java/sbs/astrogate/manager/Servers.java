package sbs.astrogate.manager;

import com.jcraft.jsch.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Consumer;
import org.json.*;

final class Servers {
  private final Map<String, Session> sessions = new ConcurrentHashMap<>();
  private final Map<String, ChannelShell> shells = new ConcurrentHashMap<>();
  private final Map<String, OutputStream> inputs = new ConcurrentHashMap<>();
  private final Consumer<JSONObject> events;

  Servers(Consumer<JSONObject> events) {
    this.events = events;
  }

  static String quote(String s) {
    return "'" + s.replace("'", "'\"'\"'") + "'";
  }

  synchronized Session connect(JSONObject server) throws Exception {
    String id = server.getString("id");
    Session existing = sessions.get(id);
    if (existing != null && existing.isConnected()) return existing;
    JSch jsch = new JSch();
    String key = server.optString("privateKey");
    if (!key.isEmpty())
      jsch.addIdentity(
          id,
          key.getBytes(StandardCharsets.UTF_8),
          null,
          server.optString("passphrase").getBytes(StandardCharsets.UTF_8));
    String[] encountered = {""};
    String trusted = server.optString("fingerprint");
    jsch.setHostKeyRepository(
        new HostKeyRepository() {
          public int check(String host, byte[] key) {
            try {
              encountered[0] =
                  "SHA256:"
                      + Base64.getEncoder()
                          .withoutPadding()
                          .encodeToString(MessageDigest.getInstance("SHA-256").digest(key));
              return encountered[0].equals(trusted)
                  ? OK
                  : (trusted.isEmpty() ? NOT_INCLUDED : CHANGED);
            } catch (Exception e) {
              return CHANGED;
            }
          }

          public void add(HostKey k, UserInfo u) {}

          public void remove(String h, String t) {}

          public void remove(String h, String t, byte[] k) {}

          public String getKnownHostsRepositoryID() {
            return "AstroGate";
          }

          public HostKey[] getHostKey() {
            return new HostKey[0];
          }

          public HostKey[] getHostKey(String h, String t) {
            return new HostKey[0];
          }
        });
    Session session =
        jsch.getSession(
            server.getString("username"), server.getString("host"), server.optInt("port", 22));
    session.setConfig("StrictHostKeyChecking", "yes");
    session.setConfig("PreferredAuthentications", "publickey,password,keyboard-interactive");
    session.setPassword(server.optString("password"));
    session.setServerAliveInterval(20000);
    try {
      session.connect(20000);
    } catch (Exception e) {
      session.disconnect();
      if (!encountered[0].isEmpty() && !encountered[0].equals(trusted))
        throw new Exception("HOST_KEY|" + id + "|" + encountered[0] + "|" + trusted);
      throw new Exception("SSH 连接失败：" + e.getMessage());
    }
    sessions.put(id, session);
    return session;
  }

  synchronized void terminal(JSONObject server) throws Exception {
    String id = server.getString("id");
    Session session = connect(server);
    if (shells.containsKey(id) && shells.get(id).isConnected()) return;
    ChannelShell shell = (ChannelShell) session.openChannel("shell");
    shell.setPtyType("xterm", 90, 28, 0, 0);
    InputStream output = shell.getInputStream();
    inputs.put(id, shell.getOutputStream());
    shell.connect(15000);
    shells.put(id, shell);
    new Thread(
            () -> {
              try {
                InputStreamReader reader = new InputStreamReader(output, StandardCharsets.UTF_8);
                char[] buf = new char[4096];
                int n;
                while ((n = reader.read(buf)) != -1)
                  events.accept(
                      new JSONObject()
                          .put("event", "terminal")
                          .put("serverId", id)
                          .put("text", new String(buf, 0, n)));
              } catch (Exception ignored) {
              } finally {
                try {
                  events.accept(
                      new JSONObject().put("event", "terminalClosed").put("serverId", id));
                } catch (Exception ignored) {
                }
              }
            },
            "ssh-output")
        .start();
  }

  void resize(String id, int cols, int rows) {
    ChannelShell shell = shells.get(id);
    if (shell != null)
      shell.setPtySize(Math.max(20, Math.min(300, cols)), Math.max(5, Math.min(200, rows)), 0, 0);
  }

  void input(String id, String text) throws Exception {
    OutputStream stream = inputs.get(id);
    if (stream == null) throw new Exception("终端尚未连接");
    synchronized (stream) {
      stream.write(text.getBytes(StandardCharsets.UTF_8));
      stream.flush();
    }
  }

  String execute(JSONObject server, String command) throws Exception {
    ChannelExec channel = (ChannelExec) connect(server).openChannel("exec");
    channel.setCommand(command);
    channel.setInputStream(null);
    ByteArrayOutputStream errors = new ByteArrayOutputStream();
    channel.setErrStream(errors);
    InputStream in = channel.getInputStream();
    channel.connect(15000);
    try {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buffer = new byte[8192];
      long end = System.currentTimeMillis() + 600000;
      while (!channel.isClosed() || in.available() > 0) {
        while (in.available() > 0) {
          int n = in.read(buffer);
          if (n < 0) break;
          if (out.size() + n > 2000000) throw new Exception("服务器输出过大");
          out.write(buffer, 0, n);
        }
        if (System.currentTimeMillis() > end) throw new Exception("等待超时，命令可能仍在运行，请先核实");
        Thread.sleep(50);
      }
      String result = out.toString("UTF-8");
      if (channel.getExitStatus() != 0)
        throw new Exception(
            "退出码 "
                + channel.getExitStatus()
                + "："
                + (result + errors.toString("UTF-8"))
                    .substring(
                        0, Math.min(2000, result.length() + errors.toString("UTF-8").length())));
      return result;
    } finally {
      channel.disconnect();
    }
  }

  ChannelSftp sftp(JSONObject server) throws Exception {
    ChannelSftp channel = (ChannelSftp) connect(server).openChannel("sftp");
    channel.connect(15000);
    return channel;
  }

  JSONArray list(JSONObject server, String path) throws Exception {
    ChannelSftp channel = sftp(server);
    try {
      JSONArray rows = new JSONArray();
      for (Object item : channel.ls(path)) {
        ChannelSftp.LsEntry entry = (ChannelSftp.LsEntry) item;
        if (entry.getFilename().equals(".") || entry.getFilename().equals("..")) continue;
        rows.put(
            new JSONObject()
                .put("name", entry.getFilename())
                .put("directory", entry.getAttrs().isDir())
                .put("size", entry.getAttrs().getSize())
                .put("path", path.replaceAll("/+$", "") + "/" + entry.getFilename()));
      }
      return rows;
    } finally {
      channel.disconnect();
    }
  }

  synchronized void disconnect(String id) {
    ChannelShell shell = shells.remove(id);
    if (shell != null) shell.disconnect();
    inputs.remove(id);
    Session session = sessions.remove(id);
    if (session != null) session.disconnect();
  }

  void close() {
    for (String id : new ArrayList<>(sessions.keySet())) disconnect(id);
  }
}
