package sbs.astrogate.manager;

import java.io.*;
import org.apache.commons.net.ftp.*;
import org.json.*;

/** Passive FTP for existing non-SSH servers; independent of SSH credentials/trust. */
final class FTPFiles implements AutoCloseable {
  private final FTPClient client = new FTPClient();

  FTPFiles(JSONObject server) throws Exception {
    try {
      client.setConnectTimeout(15000);
      client.setDefaultTimeout(30000);
      client.setControlEncoding("UTF-8");
      client.connect(server.getString("host"), server.optInt("port", 21));
      if (!FTPReply.isPositiveCompletion(client.getReplyCode())
          || !client.login(server.getString("username"), server.optString("password")))
        throw new IOException("FTP 登录失败");
      client.enterLocalPassiveMode();
      client.setFileType(FTP.BINARY_FILE_TYPE);
    } catch (Exception e) {
      close();
      throw e;
    }
  }

  JSONArray list(String path) throws Exception {
    JSONArray out = new JSONArray();
    FTPFile[] files = client.listFiles(path);
    if (!FTPReply.isPositiveCompletion(client.getReplyCode())) throw new IOException("目录读取失败");
    for (FTPFile f : files)
      if (!f.getName().equals(".") && !f.getName().equals(".."))
        out.put(
            new JSONObject()
                .put("name", f.getName())
                .put("path", path.replaceAll("/+$", "") + "/" + f.getName())
                .put("directory", f.isDirectory())
                .put("size", f.getSize()));
    return out;
  }

  long size(String path) throws Exception {
    FTPFile[] files = client.listFiles(path);
    if (files.length != 1 || files[0].isDirectory()) throw new IOException("文件不存在");
    return files[0].getSize();
  }

  void get(String path, OutputStream output) throws Exception {
    if (!client.retrieveFile(path, output)) throw new IOException("FTP 下载失败");
  }

  void put(String path, InputStream input) throws Exception {
    if (client.listFiles(path).length > 0) throw new IOException("远端同名文件已存在，请重命名后上传");
    if (!client.storeFile(path, input)) throw new IOException("FTP 上传失败");
  }

  void create(String path, boolean directory) throws Exception {
    if (directory) {
      if (!client.makeDirectory(path)) throw new IOException("创建文件夹失败");
    } else put(path, new ByteArrayInputStream(new byte[0]));
  }

  void delete(String path, boolean directory) throws Exception {
    if (!(directory ? client.removeDirectory(path) : client.deleteFile(path)))
      throw new IOException("删除失败，请先清空文件夹");
  }

  public void close() {
    try {
      if (client.isConnected()) client.disconnect();
    } catch (Exception ignored) {
    }
  }
}
