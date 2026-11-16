package sbs.astrogate.manager;

import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import okhttp3.*;
import org.json.*;

final class AIClient {
  private final OkHttpClient http;

  AIClient() {
    this(
        new OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(90, TimeUnit.SECONDS)
            .callTimeout(240, TimeUnit.SECONDS)
            .build());
  }

  AIClient(OkHttpClient client) {
    http = client;
  }

  private volatile Call active;

  static HttpUrl endpoint(String address, String suffix) throws Exception {
    HttpUrl url = HttpUrl.parse(address.trim());
    if (url == null
        || !url.isHttps()
        || !url.username().isEmpty()
        || !url.password().isEmpty()
        || url.query() != null
        || url.fragment() != null) throw new Exception("请填写 HTTPS API 地址，不要把密钥放在网址里");
    String path = url.encodedPath().replaceAll("/+$", "").replaceFirst("/chat/completions$", "");
    if (path.isEmpty()) path = "/v1";
    return url.newBuilder().encodedPath(path + "/" + suffix).build();
  }

  private Request.Builder request(JSONObject config, String suffix) throws Exception {
    String key = config.optString("apiKey").trim();
    if (key.isEmpty() || key.contains("\n") || key.contains("\r"))
      throw new Exception("请在设置中填写 API Key");
    return new Request.Builder()
        .url(endpoint(config.optString("address"), suffix))
        .header("Authorization", "Bearer " + key);
  }

  private void check(Response r) throws Exception {
    if (r.code() != 200)
      throw new Exception(
          "中转站返回 HTTP "
              + r.code()
              + (r.code() == 401 || r.code() == 403
                  ? "，请检查 API Key 和权限"
                  : r.code() == 404 ? "，请检查 API 地址" : ""));
  }

  JSONArray models(JSONObject config) throws Exception {
    try (Response r = http.newCall(request(config, "models").build()).execute()) {
      check(r);
      okio.Buffer buffer = new okio.Buffer();
      long count = 0, n;
      while ((n = r.body().source().read(buffer, 8192)) != -1) {
        count += n;
        if (count > 2000000) throw new Exception("模型列表过大");
      }
      JSONObject object = new JSONObject(buffer.readUtf8());
      JSONArray data = object.getJSONArray("data");
      TreeSet<String> ids = new TreeSet<>();
      for (int i = 0; i < data.length(); i++) {
        String id = data.getJSONObject(i).optString("id");
        if (!id.isEmpty() && id.length() < 200) ids.add(id);
      }
      if (ids.isEmpty()) throw new Exception("API Key 没有可用模型");
      return new JSONArray(ids);
    }
  }

  JSONObject complete(JSONObject config, JSONArray messages, Consumer<String> text)
      throws Exception {
    if (config.optString("model").trim().isEmpty()) throw new Exception("请先选择并保存模型");
    JSONObject tool =
        new JSONObject(
            "{\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"description\":\"Propose"
                + " a Linux SSH command for user approval. Never read"
                + " secrets.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"reason\":{\"type\":\"string\"}},\"required\":[\"command\",\"reason\"]}}}");
    JSONObject body =
        new JSONObject()
            .put("model", config.getString("model"))
            .put("messages", messages)
            .put("stream", true)
            .put("tools", new JSONArray().put(tool))
            .put("tool_choice", "auto");
    if (body.toString().length() > 600000) throw new Exception("上下文过长，请新建聊天");
    Call call =
        http.newCall(
            request(config, "chat/completions")
                .header("Accept", "text/event-stream")
                .post(RequestBody.create(body.toString(), MediaType.parse("application/json")))
                .build());
    active = call;
    try (Response r = call.execute()) {
      check(r);
      if (!r.header("Content-Type", "").contains("text/event-stream"))
        throw new Exception("中转站未返回流式响应");
      StringBuilder output = new StringBuilder();
      TreeMap<Integer, JSONObject> calls = new TreeMap<>();
      long last = 0, total = 0;
      boolean finished = false;
      while (!r.body().source().exhausted()) {
        String line = r.body().source().readUtf8LineStrict(1000000);
        total += line.length();
        if (total > 1000000) throw new Exception("回复过大");
        if (!line.startsWith("data:")) continue;
        String payload = line.substring(5).trim();
        if (payload.equals("[DONE]")) {
          finished = true;
          break;
        }
        JSONObject event = new JSONObject(payload);
        if (event.has("error")) throw new Exception("中转站返回错误，请检查模型或额度");
        JSONArray choices = event.optJSONArray("choices");
        if (choices == null || choices.length() == 0) continue;
        JSONObject choice = choices.getJSONObject(0);
        String reason = choice.optString("finish_reason", "");
        if (!reason.isEmpty() && !reason.equals("null")) {
          if (!reason.equals("stop") && !reason.equals("tool_calls"))
            throw new Exception("模型输出未完成：" + reason);
          finished = true;
        }
        JSONObject delta = choice.optJSONObject("delta");
        if (delta == null) continue;
        if (!delta.isNull("content")) output.append(delta.optString("content"));
        JSONArray items = delta.optJSONArray("tool_calls");
        if (items != null)
          for (int i = 0; i < items.length(); i++) {
            JSONObject item = items.getJSONObject(i);
            int index = item.getInt("index");
            if (index < 0 || index > 3) throw new Exception("单次命令数量过多");
            JSONObject acc = calls.computeIfAbsent(index, k -> new JSONObject());
            acc.put("id", acc.optString("id") + item.optString("id"));
            JSONObject fn = item.optJSONObject("function");
            if (fn != null) {
              acc.put("name", acc.optString("name") + fn.optString("name"));
              acc.put("arguments", acc.optString("arguments") + fn.optString("arguments"));
            }
          }
        if (System.currentTimeMillis() - last > 80) {
          text.accept(output.toString());
          last = System.currentTimeMillis();
        }
      }
      if (!finished) throw new Exception("输出连接中断，未执行新命令");
      text.accept(output.toString());
      JSONArray tools = new JSONArray();
      for (JSONObject callInfo : calls.values()) {
        JSONObject args = new JSONObject(callInfo.optString("arguments"));
        if (!callInfo.optString("name").equals("run_command")
            || callInfo.optString("id").isEmpty()
            || args.optString("command").isEmpty()
            || args.optString("command").length() > 16000) throw new Exception("模型返回了无效命令");
        tools.put(
            new JSONObject()
                .put("id", callInfo.getString("id"))
                .put("type", "function")
                .put(
                    "function",
                    new JSONObject().put("name", "run_command").put("arguments", args.toString())));
      }
      JSONObject result =
          new JSONObject().put("role", "assistant").put("content", output.toString());
      if (tools.length() > 0) result.put("tool_calls", tools);
      return result;
    } finally {
      if (active == call) active = null;
    }
  }

  void cancel() {
    Call call = active;
    if (call != null) call.cancel();
  }
}
