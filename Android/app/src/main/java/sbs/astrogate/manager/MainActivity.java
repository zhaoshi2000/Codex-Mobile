package sbs.astrogate.manager;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.provider.*;
import android.view.*;
import android.webkit.*;
import com.jcraft.jsch.ChannelSftp;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

public class MainActivity extends Activity {
  private WebView web;
  private Vault vault;
  private JSONObject state;
  private final ExecutorService workers = Executors.newFixedThreadPool(6);
  private CodexClient codex;
  private Servers servers;
  private final AIClient ai = new AIClient();
  private String pickerId, scanId;
  private volatile boolean cancelDownload;
  private final java.util.concurrent.atomic.AtomicBoolean downloadBusy =
      new java.util.concurrent.atomic.AtomicBoolean();
  private final Map<String, String> thumbnails =
      Collections.synchronizedMap(
          new LinkedHashMap<String, String>(64, .75f, true) {
            protected boolean removeEldestEntry(Map.Entry<String, String> e) {
              return size() > 48;
            }
          });
  private final Map<String, String> previews = new ConcurrentHashMap<>();
  private String currentHost = "";
  private boolean background;
  private final Set<String> notified = ConcurrentHashMap.newKeySet();

  @Override
  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    try {
      vault = new Vault(this);
      state = vault.load();
      if (!state.has("devices")) state.put("devices", new JSONArray());
      if (!state.has("servers")) state.put("servers", new JSONArray());
      codex = new CodexClient(this::event);
      servers = new Servers(this::event);
      web = new WebView(this);
      android.widget.FrameLayout container = new android.widget.FrameLayout(this);
      container.addView(web, new android.widget.FrameLayout.LayoutParams(-1, -1));
      setContentView(container);
      getWindow()
          .getDecorView()
          .setSystemUiVisibility(
              View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                  | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                  | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                  | ((getResources().getConfiguration().uiMode
                              & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                          == android.content.res.Configuration.UI_MODE_NIGHT_YES
                      ? 0
                      : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                          | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR));
      if ((getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0)
        WebView.setWebContentsDebuggingEnabled(true);
      web.setBackgroundColor(0xfff5f6fa);
      web.getSettings().setJavaScriptEnabled(true);
      web.getSettings().setDomStorageEnabled(false);
      web.getSettings().setAllowFileAccess(false);
      web.getSettings().setAllowContentAccess(false);
      web.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
      web.addJavascriptInterface(new Bridge(), "Native");
      web.setWebChromeClient(new WebChromeClient());
      web.setWebViewClient(
          new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(
                WebView v, WebResourceRequest request) {
              Uri uri = request.getUrl();
              if (uri.getHost() != null && uri.getHost().equals("app.astrogate.local")) {
                try {
                  String asset = uri.getPath().substring(1);
                  if (asset.contains("..")) return blocked();
                  return new WebResourceResponse(
                      asset.endsWith(".js")
                          ? "text/javascript"
                          : asset.endsWith(".css") ? "text/css" : "text/html",
                      "UTF-8",
                      getAssets().open(asset));
                } catch (Exception e) {
                  return blocked();
                }
              }
              return blocked();
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
              return true;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
              if (getIntent().getData() != null) {
                emit("pairLink", "uri", getIntent().getData().toString());
                getIntent().setData(null);
              }
            }
          });
      container.setOnApplyWindowInsetsListener(
          (v, insets) -> {
            int top = insets.getSystemWindowInsetTop(),
                bottom = insets.getSystemWindowInsetBottom();
            v.setPadding(0, top, 0, bottom);
            return insets;
          });
      web.loadUrl("https://app.astrogate.local/index.html");
      NotificationManager nm = getSystemService(NotificationManager.class);
      nm.createNotificationChannel(
          new NotificationChannel("completed", "任务完成提醒", NotificationManager.IMPORTANCE_DEFAULT));
    } catch (Exception e) {
      new AlertDialog.Builder(this)
          .setMessage("启动失败：" + CodexClient.cause(e))
          .setPositiveButton("关闭", (d, w) -> finish())
          .show();
    }
  }

  @Override
  protected void onNewIntent(Intent intent) {
    super.onNewIntent(intent);
    setIntent(intent);
    if (intent.getData() != null && web != null) {
      emit("pairLink", "uri", intent.getData().toString());
      intent.setData(null);
    }
  }

  private static WebResourceResponse blocked() {
    return new WebResourceResponse("text/plain", "UTF-8", new ByteArrayInputStream(new byte[0]));
  }

  @Override
  public void onBackPressed() {
    if (web != null) web.evaluateJavascript("window.goBack&&goBack()", null);
    else super.onBackPressed();
  }

  @Override
  protected void onResume() {
    super.onResume();
    background = false;
    if (web != null) event(CodexClient.obj("event", "resume"));
  }

  @Override
  protected void onPause() {
    super.onPause();
    background = true;
  }

  @Override
  protected void onDestroy() {
    if (codex != null) codex.disconnect();
    if (servers != null) servers.close();
    ai.cancel();
    workers.shutdownNow();
    if (web != null) web.destroy();
    super.onDestroy();
  }

  private void emit(String type, String key, Object value) {
    try {
      event(new JSONObject().put("event", type).put(key, value));
    } catch (Exception ignored) {
    }
  }

  private void event(JSONObject event) {
    if (web == null) return;
    runOnUiThread(
        () ->
            web.evaluateJavascript(
                "window.nativeEvent&&nativeEvent(" + event.toString() + ")", null));
  }

  private void reply(String id, Object value, Exception error) {
    try {
      JSONObject message = new JSONObject().put("id", id);
      if (error == null) message.put("result", value == null ? JSONObject.NULL : value);
      else message.put("error", CodexClient.cause(error));
      runOnUiThread(
          () -> web.evaluateJavascript("window.nativeReply&&nativeReply(" + message + ")", null));
    } catch (Exception ignored) {
    }
  }

  private synchronized void save() throws Exception {
    vault.save(state);
  }

  private synchronized JSONObject boot() throws Exception {
    JSONObject out = new JSONObject(state.toString());
    out.put(
        "dark",
        (getResources().getConfiguration().uiMode
                & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
            == android.content.res.Configuration.UI_MODE_NIGHT_YES);
    out.remove("identity");
    for (String kind : new String[] {"devices", "servers"}) {
      JSONArray list = out.getJSONArray(kind);
      for (int i = 0; i < list.length(); i++) {
        JSONObject row = list.getJSONObject(i);
        row.remove("pairToken");
        row.put("hasPrivateKey", !row.optString("privateKey").isEmpty());
        row.remove("privateKey");
        row.remove("password");
        row.remove("passphrase");
      }
    }
    JSONObject config = out.optJSONObject("ai");
    if (config != null) {
      config.put("hasKey", !config.optString("apiKey").isEmpty());
      config.remove("apiKey");
    }
    out.put("connected", codex.connected());
    return out;
  }

  private synchronized JSONObject find(String kind, String id) throws Exception {
    JSONArray list = state.getJSONArray(kind);
    for (int i = 0; i < list.length(); i++) {
      JSONObject row = list.getJSONObject(i);
      if (row.optString(kind.equals("devices") ? "hostId" : "id").equals(id))
        return new JSONObject(row.toString());
    }
    throw new Exception("连接已移除");
  }

  private synchronized void put(String kind, JSONObject row) throws Exception {
    String key = kind.equals("devices") ? "hostId" : "id";
    JSONArray rows = state.getJSONArray(kind), next = new JSONArray();
    for (int i = 0; i < rows.length(); i++)
      if (!rows.getJSONObject(i).optString(key).equals(row.getString(key))) next.put(rows.get(i));
    next.put(row);
    state.put(kind, next);
    save();
  }

  private synchronized JSONObject config(JSONObject fields) throws Exception {
    JSONObject c = state.optJSONObject("ai");
    c = c == null ? new JSONObject() : new JSONObject(c.toString());
    for (String key : new String[] {"address", "model", "apiKey"})
      if (fields.has(key) && !(key.equals("apiKey") && fields.optString(key).isEmpty()))
        c.put(key, fields.getString(key).trim());
    return c;
  }

  private File local(String relative) throws Exception {
    File root = new File(getFilesDir(), "files");
    root.mkdirs();
    File file = new File(root, relative).getCanonicalFile();
    if (!file.toPath().startsWith(root.getCanonicalFile().toPath()))
      throw new Exception("文件路径不允许访问");
    return file;
  }

  private String relative(File file) throws Exception {
    return local("").toPath().relativize(file.toPath()).toString();
  }

  private String safe(String name) {
    String s = name.replaceAll("[<>:\"/\\\\|?*\\x00-\\x1f]", "_").replaceAll("[. ]+$", "");
    return s.trim().isEmpty() ? "文件" : s.substring(0, Math.min(s.length(), 150));
  }

  private File unique(String folder, String name) throws Exception {
    File dir = local(folder);
    dir.mkdirs();
    File target = new File(dir, safe(name));
    int n = 1;
    while (target.exists()) target = new File(dir, (n++) + "-" + safe(name));
    return target;
  }

  private JSONObject fileInfo(File file) throws Exception {
    return new JSONObject()
        .put("name", file.getName())
        .put("path", relative(file))
        .put("directory", file.isDirectory())
        .put("size", file.length());
  }

  private void progress(String name, long done, long total, String phase) throws Exception {
    event(
        new JSONObject()
            .put("event", "download")
            .put("name", name)
            .put("received", done)
            .put("total", total)
            .put("phase", phase));
  }

  private String digest(File file) throws Exception {
    MessageDigest hash = MessageDigest.getInstance("SHA-256");
    try (InputStream input = new FileInputStream(file)) {
      byte[] buf = new byte[65536];
      int n;
      while ((n = input.read(buf)) != -1) hash.update(buf, 0, n);
    }
    return hex(hash.digest());
  }

  static String hex(byte[] bytes) {
    StringBuilder out = new StringBuilder();
    for (byte b : bytes) out.append(String.format("%02x", b));
    return out.toString();
  }

  private JSONObject download(JSONObject p) throws Exception {
    String cacheKey = currentHost + "|" + p.toString();
    String cached = previews.get(cacheKey);
    if (cached != null && local(cached).exists()) return fileInfo(local(cached));
    cancelDownload = false;
    progress("正在准备文件", 0, 0, "preparing");
    JSONObject info = codex.request("filePrepare", p);
    String id = info.getString("id"), name = info.getString("name");
    long size = info.getLong("size");
    File temp = File.createTempFile("download-", ".part", getCacheDir());
    try {
      if (size < 0 || size > 200L * 1024 * 1024) throw new Exception("文件最大 200 MB");
      MessageDigest hash = MessageDigest.getInstance("SHA-256");
      long offset = 0;
      try (OutputStream output = new FileOutputStream(temp)) {
        while (offset < size) {
          if (cancelDownload) throw new Exception("下载已取消");
          JSONObject chunk =
              codex.request("fileChunk", new JSONObject().put("fileId", id).put("offset", offset));
          byte[] bytes = Base64.getDecoder().decode(chunk.getString("data"));
          if (chunk.getLong("offset") != offset
              || bytes.length == 0
              || bytes.length > 192 * 1024
              || offset + bytes.length > size) throw new Exception("文件分块无效");
          output.write(bytes);
          hash.update(bytes);
          offset += bytes.length;
          progress(name, offset, size, "receiving");
        }
      }
      progress(name, size, size, "verifying");
      if (!hex(hash.digest()).equals(info.getString("sha256"))) throw new Exception("文件完整性校验失败");
      File target = unique("Codex 下载", name);
      Files.move(temp.toPath(), target.toPath());
      JSONObject file = fileInfo(target);
      previews.put(cacheKey, file.getString("path"));
      event(new JSONObject().put("event", "download").put("phase", "saved").put("file", file));
      return file;
    } catch (Exception e) {
      event(
          new JSONObject()
              .put("event", "download")
              .put("phase", "failed")
              .put("message", CodexClient.cause(e)));
      throw e;
    } finally {
      temp.delete();
      try {
        codex.request("fileRelease", new JSONObject().put("fileId", id));
      } catch (Exception ignored) {
      }
    }
  }

  private JSONObject upload(JSONObject p) throws Exception {
    File file = local(p.getString("path"));
    if (file.length() > 25L * 1024 * 1024) throw new Exception("单个附件最大 25 MB");
    JSONObject init =
        new JSONObject()
            .put("threadId", p.getString("threadId"))
            .put("name", safe(p.optString("name", file.getName())))
            .put("size", file.length())
            .put("sha256", digest(file));
    String id = codex.request("uploadBegin", init).getString("id");
    long offset = 0;
    try (InputStream in = new FileInputStream(file)) {
      byte[] buffer = new byte[192 * 1024];
      int n;
      while ((n = in.read(buffer)) != -1) {
        JSONObject ack =
            codex.request(
                "uploadChunk",
                new JSONObject()
                    .put("id", id)
                    .put("offset", offset)
                    .put("data", Base64.getEncoder().encodeToString(Arrays.copyOf(buffer, n))));
        offset += n;
        if (ack.getLong("offset") != offset) throw new Exception("附件上传位置不一致");
        event(
            new JSONObject()
                .put("event", "upload")
                .put("received", offset)
                .put("total", file.length()));
      }
      return codex.request("uploadFinish", new JSONObject().put("id", id));
    } catch (Exception e) {
      try {
        codex.request("uploadCancel", new JSONObject().put("id", id));
      } catch (Exception ignored) {
      }
      throw e;
    }
  }

  private void openFile(File file, boolean share) throws Exception {
    Uri uri = FilesProvider.uri(this, file);
    String mime = FilesProvider.mime(file.getName());
    Intent intent = new Intent(share ? Intent.ACTION_SEND : Intent.ACTION_VIEW);
    if (share) {
      intent.setType(mime);
      intent.putExtra(Intent.EXTRA_STREAM, uri);
    } else intent.setDataAndType(uri, mime);
    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
    runOnUiThread(
        () -> {
          try {
            startActivity(Intent.createChooser(intent, share ? "分享 / 导出" : "打开文件"));
          } catch (Exception e) {
            emit("error", "message", CodexClient.cause(e));
          }
        });
  }

  public class Bridge {
    @JavascriptInterface
    public void call(String id, String operation, String args) {
      if (args.length() > 2000000) {
        reply(id, null, new Exception("请求过大"));
        return;
      }
      workers.execute(
          () -> {
            try {
              JSONObject p = new JSONObject(args);
              if (operation.equals("pick") || operation.equals("scan")) {
                runOnUiThread(
                    () -> {
                      try {
                        if (pickerId != null || scanId != null) throw new Exception("已有选择窗口正在打开");
                        if (operation.equals("pick")) {
                          pickerId = id;
                          Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                          intent.setType(p.optBoolean("photos") ? "image/*" : "*/*");
                          intent.addCategory(Intent.CATEGORY_OPENABLE);
                          intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                          startActivityForResult(intent, 100);
                        } else {
                          scanId = id;
                          if (checkSelfPermission(Manifest.permission.CAMERA)
                              != PackageManager.PERMISSION_GRANTED)
                            requestPermissions(new String[] {Manifest.permission.CAMERA}, 201);
                          else
                            startActivityForResult(
                                new Intent(MainActivity.this, ScanActivity.class), 101);
                        }
                      } catch (Exception e) {
                        pickerId = null;
                        scanId = null;
                        reply(id, null, e);
                      }
                    });
                return;
              }
              reply(id, dispatch(operation, p), null);
            } catch (Exception e) {
              reply(id, null, e);
            }
          });
    }
  }

  private Object ftp(String operation, JSONObject p, JSONObject server) throws Exception {
    try (FTPFiles ftp = new FTPFiles(server)) {
      String path = p.optString("path", ".");
      switch (operation) {
        case "sftpList":
          return ftp.list(path);
        case "sftpGet":
          {
            long size = ftp.size(path);
            if (size < 0 || size > 200L * 1024 * 1024) throw new IOException("文件最大 200 MB");
            File file = unique("FTP 下载", path.substring(path.lastIndexOf('/') + 1));
            cancelDownload = false;
            try (OutputStream raw = new FileOutputStream(file)) {
              ftp.get(
                  path,
                  new OutputStream() {
                    long count;

                    public void write(int b) throws IOException {
                      write(new byte[] {(byte) b});
                    }

                    public void write(byte[] b, int offset, int length) throws IOException {
                      if (cancelDownload) throw new IOException("下载已取消");
                      count += length;
                      if (count > 200L * 1024 * 1024) throw new IOException("文件过大");
                      raw.write(b, offset, length);
                      try {
                        progress(file.getName(), count, size, "receiving");
                      } catch (Exception ignored) {
                      }
                    }
                  });
              JSONObject info = fileInfo(file);
              event(
                  new JSONObject()
                      .put("event", "download")
                      .put("phase", "saved")
                      .put("file", info));
              return info;
            } catch (Exception e) {
              file.delete();
              throw e;
            }
          }
        case "sftpPut":
          try (InputStream input = new FileInputStream(local(path))) {
            ftp.put(p.getString("remote"), input);
            return true;
          }
        case "sftpCreate":
          ftp.create(path, p.optBoolean("directory"));
          return true;
        case "sftpDelete":
          ftp.delete(path, p.optBoolean("directory"));
          return true;
        default:
          throw new IOException("不支持的 FTP 操作");
      }
    }
  }

  private Object dispatch(String operation, JSONObject p) throws Exception {
    if (operation.startsWith("sftp")
        && find("servers", p.getString("id")).optString("type").equals("ftp"))
      return ftp(operation, p, find("servers", p.getString("id")));
    switch (operation) {
      case "exit":
        runOnUiThread(this::finish);
        return true;
      case "boot":
        return boot();
      case "pair":
        {
          Uri uri = Uri.parse(p.getString("uri").trim());
          if (!"ifilecodex".equals(uri.getScheme()) || !"pair".equals(uri.getHost()))
            throw new Exception("请扫描电脑连接程序的配对二维码");
          String encoded = uri.getQueryParameter("data");
          if (encoded == null || encoded.length() > 12000) throw new Exception("二维码无效");
          JSONObject d =
              new JSONObject(new String(SecureWire.un64(encoded), StandardCharsets.UTF_8));
          UUID.fromString(d.getString("hostId"));
          Uri relay = Uri.parse(d.getString("relay"));
          if (d.getInt("version") != 1
              || !"wss".equals(relay.getScheme())
              || relay.getHost() == null
              || relay.getUserInfo() != null
              || relay.getQuery() != null
              || relay.getFragment() != null
              || relay.getPath().contains("..")
              || SecureWire.un64(d.getString("hostKey")).length != 32
              || d.optString("pairToken").length() < 32
              || d.optLong("expires") < System.currentTimeMillis())
            throw new Exception("二维码无效或已过期，请在电脑刷新");
          JSONArray devices = state.getJSONArray("devices");
          for (int i = 0; i < devices.length(); i++) {
            JSONObject old = devices.getJSONObject(i);
            if (old.getString("hostId").equals(d.getString("hostId"))) {
              if (!old.getString("hostKey").equals(d.getString("hostKey")))
                throw new Exception("电脑身份密钥已改变，请核实后移除旧设备再配对");
              d.put("alias", old.optString("alias"));
            }
          }
          put("devices", d);
          return boot();
        }
      case "connect":
        {
          JSONObject device = find("devices", p.getString("id"));
          byte[] secret;
          synchronized (this) {
            if (!state.has("identity")) {
              state.put("identity", SecureWire.b64(SecureWire.identity()));
              save();
            }
            secret = SecureWire.un64(state.getString("identity"));
          }
          currentHost = device.getString("hostId");
          JSONObject ready = codex.connect(device, secret);
          device.remove("pairToken");
          device.remove("expires");
          put("devices", device);
          return ready;
        }
      case "disconnect":
        codex.disconnect();
        return true;
      case "rpc":
        return codex.request(
            p.getString("method"),
            p.optJSONObject("params") == null ? new JSONObject() : p.getJSONObject("params"));
      case "renameDevice":
        {
          JSONObject d = find("devices", p.getString("id"));
          d.put("alias", p.getString("name").trim());
          put("devices", d);
          return boot();
        }
      case "remove":
        {
          String kind = p.getString("kind");
          if (!kind.equals("devices") && !kind.equals("servers")) throw new Exception("类型无效");
          JSONArray old = state.getJSONArray(kind), next = new JSONArray();
          for (int i = 0; i < old.length(); i++) {
            JSONObject row = old.getJSONObject(i);
            if (!row.optString(kind.equals("devices") ? "hostId" : "id").equals(p.getString("id")))
              next.put(row);
          }
          state.put(kind, next);
          save();
          if (kind.equals("servers")) servers.disconnect(p.getString("id"));
          else if (currentHost.equals(p.getString("id"))) codex.disconnect();
          return boot();
        }
      case "thumbnail":
        {
          String key = currentHost + "|" + p.toString();
          if (thumbnails.containsKey(key)) return thumbnails.get(key);
          JSONObject result = codex.request("imageThumbnail", p);
          String url = "data:image/jpeg;base64," + result.getString("data");
          thumbnails.put(key, url);
          return url;
        }
      case "download":
        if (!downloadBusy.compareAndSet(false, true)) throw new Exception("已有文件正在下载，请稍后再试");
        try {
          return download(p);
        } finally {
          downloadBusy.set(false);
        }
      case "cancelDownload":
        cancelDownload = true;
        return true;
      case "upload":
        return upload(p);
      case "localList":
        {
          JSONArray rows = new JSONArray();
          File[] files = local(p.optString("path")).listFiles();
          if (files == null) throw new Exception("目录读取失败");
          Arrays.sort(
              files,
              Comparator.comparing((File f) -> !f.isDirectory()).thenComparing(File::getName));
          for (File file : files) rows.put(fileInfo(file));
          return rows;
        }
      case "localCreate":
        {
          File folder = local(p.optString("folder")),
              file = new File(folder, safe(p.getString("name")));
          if (file.exists()) throw new Exception("同名文件已存在");
          if (p.optBoolean("directory")) {
            if (!file.mkdir()) throw new Exception("创建失败");
          } else if (!file.createNewFile()) throw new Exception("创建失败");
          return fileInfo(file);
        }
      case "localRead":
        {
          File file = local(p.getString("path"));
          if (file.length() > 2 * 1024 * 1024) throw new Exception("编辑器最多打开 2 MB 文本");
          return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
        }
      case "localWrite":
        {
          File file = local(p.getString("path"));
          if (p.getString("text").length() > 2 * 1024 * 1024) throw new Exception("文本过大");
          Files.write(file.toPath(), p.getString("text").getBytes(StandardCharsets.UTF_8));
          return true;
        }
      case "localRename":
        {
          File file = local(p.getString("path"));
          if (file.equals(local(""))) throw new Exception("不能修改根目录");
          File target = new File(file.getParentFile(), safe(p.getString("name")));
          if (target.exists() || !file.renameTo(target)) throw new Exception("重命名失败");
          return fileInfo(target);
        }
      case "localDelete":
        {
          File file = local(p.getString("path"));
          if (file.equals(local("")) || !file.delete()) throw new Exception("删除失败，请先清空文件夹");
          return true;
        }
      case "localImage":
        {
          File file = local(p.getString("path"));
          BitmapFactory.Options options = new BitmapFactory.Options();
          options.inJustDecodeBounds = true;
          BitmapFactory.decodeFile(file.getPath(), options);
          options.inSampleSize = Math.max(1, Math.max(options.outWidth, options.outHeight) / 1200);
          options.inJustDecodeBounds = false;
          Bitmap image = BitmapFactory.decodeFile(file.getPath(), options);
          if (image == null) throw new Exception("图片读取失败");
          ByteArrayOutputStream bytes = new ByteArrayOutputStream();
          image.compress(Bitmap.CompressFormat.JPEG, 85, bytes);
          image.recycle();
          return "data:image/jpeg;base64,"
              + Base64.getEncoder().encodeToString(bytes.toByteArray());
        }
      case "openFile":
        openFile(local(p.getString("path")), p.optBoolean("share"));
        return true;
      case "export":
        {
          File file = local(p.getString("path"));
          ContentValues values = new ContentValues();
          values.put(MediaStore.Downloads.DISPLAY_NAME, file.getName());
          values.put(MediaStore.Downloads.MIME_TYPE, FilesProvider.mime(file.getName()));
          values.put(MediaStore.Downloads.RELATIVE_PATH, "Download/AstroGate");
          values.put(MediaStore.Downloads.IS_PENDING, 1);
          Uri uri = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
          if (uri == null) throw new Exception("导出失败");
          try (OutputStream out = getContentResolver().openOutputStream(uri);
              InputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[65536];
            int count;
            while ((count = in.read(buffer)) != -1) out.write(buffer, 0, count);
          } catch (Exception e) {
            getContentResolver().delete(uri, null, null);
            throw e;
          }
          values.clear();
          values.put(MediaStore.Downloads.IS_PENDING, 0);
          getContentResolver().update(uri, values, null, null);
          return "已导出到 下载/AstroGate";
        }
      case "copy":
        runOnUiThread(
            () ->
                ((android.content.ClipboardManager) getSystemService(CLIPBOARD_SERVICE))
                    .setPrimaryClip(ClipData.newPlainText("AstroGate", p.optString("text"))));
        return true;
      case "browser":
        {
          Uri uri = Uri.parse(p.getString("url"));
          if (!Arrays.asList("https", "http").contains(uri.getScheme()))
            throw new Exception("链接格式不支持");
          runOnUiThread(() -> startActivity(new Intent(Intent.ACTION_VIEW, uri)));
          return true;
        }
      case "aiModels":
        return ai.models(config(p));
      case "aiSave":
        {
          JSONObject c = config(p);
          AIClient.endpoint(c.getString("address"), "models");
          if (c.optString("apiKey").isEmpty() || c.optString("model").isEmpty())
            throw new Exception("请填写 API Key 并选择模型");
          state.put("ai", c);
          save();
          return boot();
        }
      case "aiChat":
        return ai.complete(
            config(new JSONObject()),
            p.getJSONArray("messages"),
            text -> emit("aiText", "text", text));
      case "aiCancel":
        ai.cancel();
        return true;
      case "serverSave":
        {
          JSONObject server = p;
          String id = p.optString("id", UUID.randomUUID().toString());
          JSONObject old = null;
          try {
            old = find("servers", id);
          } catch (Exception ignored) {
          }
          if (old != null) {
            for (String key : new String[] {"password", "privateKey", "passphrase"})
              if (server.optString(key).isEmpty()) server.put(key, old.optString(key));
            if (server.optString("host").equals(old.optString("host"))
                && server.optInt("port", 22) == old.optInt("port", 22))
              server.put("fingerprint", old.optString("fingerprint"));
          }
          if (server.optString("host").trim().isEmpty()
              || server.optString("username").trim().isEmpty()
              || server.optInt("port", 22) < 1
              || server.optInt("port", 22) > 65535) throw new Exception("请填写服务器、端口和用户名");
          server.put("id", id);
          servers.disconnect(id);
          put("servers", server);
          return boot();
        }
      case "trustHost":
        {
          JSONObject server = find("servers", p.getString("id"));
          server.put("fingerprint", p.getString("fingerprint"));
          put("servers", server);
          return true;
        }
      case "terminal":
        servers.terminal(find("servers", p.getString("id")));
        return true;
      case "terminalResize":
        servers.resize(p.getString("id"), p.getInt("cols"), p.getInt("rows"));
        return true;
      case "terminalInput":
        servers.input(p.getString("id"), p.getString("text"));
        return true;
      case "serverDisconnect":
        servers.disconnect(p.getString("id"));
        return true;
      case "serverExec":
        {
          JSONObject server = find("servers", p.getString("id"));
          String output = servers.execute(server, p.getString("command"));
          for (String key : new String[] {"password", "privateKey", "passphrase"}) {
            String secret = server.optString(key);
            if (secret.length() > 5) output = output.replace(secret, "[已隐藏凭据]");
          }
          String apiKey = config(new JSONObject()).optString("apiKey");
          if (apiKey.length() > 5) output = output.replace(apiKey, "[已隐藏 API Key]");
          return output;
        }
      case "sftpList":
        return servers.list(find("servers", p.getString("id")), p.optString("path", "."));
      case "sftpGet":
        {
          ChannelSftp channel = servers.sftp(find("servers", p.getString("id")));
          File file =
              unique(
                  "SFTP 下载",
                  p.getString("path").substring(p.getString("path").lastIndexOf('/') + 1));
          try {
            long size = channel.stat(p.getString("path")).getSize();
            if (size > 200L * 1024 * 1024) throw new Exception("文件最大 200 MB");
            channel.get(
                p.getString("path"),
                file.getPath(),
                new com.jcraft.jsch.SftpProgressMonitor() {
                  long count;

                  public void init(int op, String src, String dst, long max) {}

                  public boolean count(long n) {
                    count += n;
                    try {
                      progress(file.getName(), count, size, "receiving");
                    } catch (Exception ignored) {
                    }
                    return true;
                  }

                  public void end() {}
                });
            JSONObject fileInfo = fileInfo(file);
            event(
                new JSONObject()
                    .put("event", "download")
                    .put("phase", "saved")
                    .put("file", fileInfo));
            return fileInfo;
          } catch (Exception e) {
            file.delete();
            throw e;
          } finally {
            channel.disconnect();
          }
        }
      case "sftpPut":
        {
          ChannelSftp channel = servers.sftp(find("servers", p.getString("id")));
          try {
            String target = p.getString("remote");
            try {
              channel.stat(target);
              throw new Exception("远端同名文件已存在，请重命名后上传");
            } catch (com.jcraft.jsch.SftpException e) {
              if (e.id != ChannelSftp.SSH_FX_NO_SUCH_FILE) throw e;
            }
            channel.put(local(p.getString("path")).getPath(), target);
            return true;
          } finally {
            channel.disconnect();
          }
        }
      case "sftpCreate":
        {
          ChannelSftp channel = servers.sftp(find("servers", p.getString("id")));
          try {
            String target = p.getString("path");
            if (p.optBoolean("directory")) channel.mkdir(target);
            else {
              try {
                channel.stat(target);
                throw new Exception("远端同名文件已存在");
              } catch (com.jcraft.jsch.SftpException e) {
                if (e.id != ChannelSftp.SSH_FX_NO_SUCH_FILE) throw e;
              }
              channel.put(new ByteArrayInputStream(new byte[0]), target);
            }
            return true;
          } finally {
            channel.disconnect();
          }
        }
      case "sftpDelete":
        {
          ChannelSftp channel = servers.sftp(find("servers", p.getString("id")));
          try {
            if (p.optBoolean("directory")) channel.rmdir(p.getString("path"));
            else channel.rm(p.getString("path"));
            return true;
          } finally {
            channel.disconnect();
          }
        }
      case "openclaw":
        {
          JSONObject server = find("servers", p.getString("id"));
          String method = p.getString("method");
          if (!Arrays.asList("sessions.list", "chat.history", "chat.send", "chat.abort")
              .contains(method)) throw new Exception("不支持的方法");
          String command = server.optString("executable", "openclaw"),
              container = server.optString("container");
          if (command.trim().isEmpty()
              || command.contains("\n")
              || command.contains("\0")
              || (!container.isEmpty() && !container.matches("[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")))
            throw new Exception("OpenClaw 配置无效");
          String runUser = server.optString("runUser");
          if (!runUser.isEmpty() && !runUser.matches("[a-zA-Z_][a-zA-Z0-9_-]{0,63}")) throw new Exception("OpenClaw 运行用户无效");
          String launcher;
          try (java.io.InputStream input = getAssets().open("openclaw-launcher.sh")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[4096]; int n;
            while ((n = input.read(buffer)) != -1) bytes.write(buffer, 0, n);
            launcher = bytes.toString("UTF-8");
          }
          String output =
              servers.execute(
                  server,
                  "sh -c " + Servers.quote(launcher) + " sh "
                      + Servers.quote(command) + " " + Servers.quote(container) + " " + Servers.quote(runUser)
                      + " gateway call "
                      + Servers.quote(method)
                      + " --params "
                      + Servers.quote(p.getJSONObject("params").toString())
                      + " --json --timeout 15000 2>&1");
          String[] lines = output.split("\n");
          for (int i = 0; i < Math.min(80, lines.length); i++) {
            try {
              JSONObject result =
                  new JSONObject(String.join("\n", Arrays.copyOfRange(lines, i, lines.length)));
              if (result.has("error") || result.optBoolean("ok", true) == false)
                throw new Exception("OpenClaw 拒绝请求");
              return result.has("payload")
                  ? result.get("payload")
                  : result.has("result") ? result.get("result") : result;
            } catch (JSONException ignored) {
            }
          }
          throw new Exception("OpenClaw 未返回有效响应，请检查配置");
        }
      case "notifyEnable":
        state.put("notifications", true);
        save();
        if (Build.VERSION.SDK_INT >= 33)
          runOnUiThread(
              () -> requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 202));
        return true;
      case "notify":
        if (state.optBoolean("notifications") && notified.add(p.getString("id"))) {
          Notification n =
              new Notification.Builder(this, "completed")
                  .setSmallIcon(sbs.astrogate.manager.R.drawable.app_icon)
                  .setContentTitle("任务已完成")
                  .setContentText(p.optString("title", "Codex 对话"))
                  .setAutoCancel(true)
                  .setContentIntent(
                      PendingIntent.getActivity(
                          this,
                          0,
                          new Intent(this, MainActivity.class),
                          PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT))
                  .build();
          if (Build.VERSION.SDK_INT < 33
              || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                  == PackageManager.PERMISSION_GRANTED)
            getSystemService(NotificationManager.class).notify(p.getString("id").hashCode(), n);
        }
        return true;
      default:
        throw new Exception("不支持的操作");
    }
  }

  @Override
  public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
    super.onRequestPermissionsResult(code, permissions, results);
    if (code == 201) {
      if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED)
        startActivityForResult(new Intent(this, ScanActivity.class), 101);
      else {
        reply(scanId, null, new Exception("未获得相机权限，可粘贴配对链接"));
        scanId = null;
      }
    }
  }

  @Override
  public void onActivityResult(int request, int result, Intent data) {
    super.onActivityResult(request, result, data);
    if (request == 101) {
      reply(scanId, result == RESULT_OK && data != null ? data.getStringExtra("qr") : null, null);
      scanId = null;
    }
    if (request == 100) {
      String id = pickerId;
      pickerId = null;
      if (result != RESULT_OK || data == null) {
        reply(id, new JSONArray(), null);
        return;
      }
      workers.execute(
          () -> {
            try {
              JSONArray files = new JSONArray();
              ArrayList<Uri> uris = new ArrayList<>();
              if (data.getClipData() != null) {
                for (int i = 0; i < Math.min(6, data.getClipData().getItemCount()); i++)
                  uris.add(data.getClipData().getItemAt(i).getUri());
              } else if (data.getData() != null) uris.add(data.getData());
              for (Uri uri : uris) {
                String name = "附件";
                try (Cursor cursor = getContentResolver().query(uri, null, null, null, null)) {
                  if (cursor != null && cursor.moveToFirst()) {
                    int index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                    if (index >= 0) name = cursor.getString(index);
                  }
                }
                File target = unique("导入", name);
                try (InputStream in = getContentResolver().openInputStream(uri);
                    OutputStream out = new FileOutputStream(target)) {
                  byte[] buffer = new byte[65536];
                  int n;
                  long total = 0;
                  while ((n = in.read(buffer)) != -1) {
                    total += n;
                    if (total > 25L * 1024 * 1024) throw new Exception("单个附件最大 25 MB");
                    out.write(buffer, 0, n);
                  }
                } catch (Exception e) {
                  target.delete();
                  throw e;
                }
                files.put(fileInfo(target));
              }
              reply(id, files, null);
            } catch (Exception e) {
              reply(id, null, e);
            }
          });
    }
  }
}
