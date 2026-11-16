package sbs.astrogate.manager;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.function.Consumer;
import okhttp3.*;
import org.json.JSONObject;

final class CodexClient {
  private final OkHttpClient http =
      new OkHttpClient.Builder()
          .pingInterval(20, TimeUnit.SECONDS)
          .readTimeout(0, TimeUnit.SECONDS)
          .build();
  private final Map<String, CompletableFuture<JSONObject>> pending = new ConcurrentHashMap<>();
  private final Consumer<JSONObject> events;
  private volatile WebSocket socket;
  private volatile SecureWire wire;
  private volatile boolean connected;
  private volatile int generation;
  private JSONObject device;
  private CompletableFuture<JSONObject> ready;

  CodexClient(Consumer<JSONObject> events) {
    this.events = events;
  }

  static JSONObject obj(String key, Object value) {
    try {
      return new JSONObject().put(key, value);
    } catch (Exception e) {
      throw new RuntimeException(e);
    }
  }

  boolean connected() {
    return connected;
  }

  JSONObject connect(JSONObject d, byte[] secret) throws Exception {
    disconnect();
    device = d;
    int attempt = generation;
    String sid = UUID.randomUUID().toString();
    ready = new CompletableFuture<>();
    CompletableFuture<JSONObject> waiting = ready;
    String url = d.getString("relay").replaceAll("/+$", "") + "/phone/" + d.getString("hostId");
    if (!url.startsWith("wss://")) throw new Exception("电脑连接需要 WSS 地址");
    socket =
        http.newWebSocket(
            new Request.Builder().url(url).build(),
            new WebSocketListener() {
              @Override
              public void onMessage(WebSocket ws, String text) {
                if (attempt != generation) return;
                try {
                  if (text.length() > 1048576) throw new Exception("消息过大");
                  JSONObject frame = new JSONObject(text);
                  if (frame.optString("type").equals("challenge")) {
                    if (wire != null || frame.getString("nonce").length() != 43)
                      throw new Exception("电脑身份验证失败");
                    wire =
                        new SecureWire(
                            secret,
                            SecureWire.un64(d.getString("hostKey")),
                            d.getString("hostId"),
                            sid + "|" + frame.getString("nonce"));
                    JSONObject hello = wire.seal(obj("pairToken", d.optString("pairToken")));
                    ws.send(
                        new JSONObject()
                            .put("type", "hello")
                            .put("sid", sid)
                            .put("publicKey", SecureWire.b64(SecureWire.publicKey(secret)))
                            .put("box", hello)
                            .toString());
                    return;
                  }
                  if (frame.optString("type").equals("rejected"))
                    throw new Exception("配对失败，二维码可能已过期，请重新扫码");
                  if (wire == null) throw new Exception("连接验证未完成");
                  JSONObject value = wire.open(frame.getJSONObject("box"));
                  if (value.has("id")) {
                    CompletableFuture<JSONObject> future = pending.remove(value.getString("id"));
                    if (future != null) {
                      if (value.has("error"))
                        future.completeExceptionally(new Exception(value.getString("error")));
                      else
                        future.complete(
                            value.optJSONObject("result") == null
                                ? new JSONObject()
                                : value.getJSONObject("result"));
                    }
                    return;
                  }
                  if (value.optString("event").equals("ready")) {
                    if (!value.optString("hostId").equals(d.getString("hostId"))
                        || value.optInt("protocolVersion") != 1) throw new Exception("电脑协议不兼容");
                    connected = true;
                    waiting.complete(value);
                  }
                  events.accept(value);
                } catch (Exception e) {
                  fail(attempt, e);
                }
              }

              @Override
              public void onMessage(WebSocket ws, okio.ByteString bytes) {
                onMessage(ws, bytes.utf8());
              }

              @Override
              public void onFailure(WebSocket ws, Throwable t, Response response) {
                fail(
                    attempt,
                    new Exception(response == null ? "网络连接中断" : ("连接失败 HTTP " + response.code())));
              }

              @Override
              public void onClosed(WebSocket ws, int code, String reason) {
                fail(attempt, new Exception("电脑连接已断开"));
              }
            });
    try {
      return waiting.get(25, TimeUnit.SECONDS);
    } catch (Exception e) {
      if (attempt == generation) disconnect();
      throw new Exception("连接未成功：" + cause(e));
    }
  }

  JSONObject request(String method, JSONObject params) throws Exception {
    String id = UUID.randomUUID().toString();
    CompletableFuture<JSONObject> future = new CompletableFuture<>();
    pending.put(id, future);
    try {
      synchronized (this) {
        if (!connected || wire == null || socket == null) throw new Exception("请先连接电脑");
        JSONObject frame =
            obj("type", "secure")
                .put(
                    "box",
                    wire.seal(
                        new JSONObject()
                            .put("id", id)
                            .put("method", method)
                            .put("params", params)));
        if (!socket.send(frame.toString())) throw new Exception("发送失败");
      }
      return future.get(75, TimeUnit.SECONDS);
    } catch (TimeoutException e) {
      throw new Exception("请求超时，送达情况待确认；请勿重复发送");
    } catch (ExecutionException e) {
      throw new Exception(cause(e));
    } finally {
      pending.remove(id);
    }
  }

  static String cause(Throwable e) {
    while (e.getCause() != null) e = e.getCause();
    return e.getMessage() == null ? "操作失败" : e.getMessage();
  }

  private void fail(int attempt, Exception error) {
    if (attempt != generation) return;
    disconnect();
    try {
      events.accept(obj("event", "disconnected").put("message", cause(error)));
    } catch (Exception ignored) {
    }
  }

  synchronized void disconnect() {
    generation++;
    connected = false;
    wire = null;
    WebSocket old = socket;
    socket = null;
    if (old != null) old.cancel();
    Exception e = new Exception("连接已断开，未确认的消息请勿重复发送");
    if (ready != null) ready.completeExceptionally(e);
    for (CompletableFuture<JSONObject> f : pending.values()) f.completeExceptionally(e);
    pending.clear();
  }
}
