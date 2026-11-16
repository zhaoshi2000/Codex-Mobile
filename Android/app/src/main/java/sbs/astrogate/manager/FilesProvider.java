package sbs.astrogate.manager;

import android.content.*;
import android.database.*;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;
import java.io.*;

/** Read-only, explicitly granted exports; never exposes credentials or app state. */
public final class FilesProvider extends ContentProvider {
  public boolean onCreate() {
    return true;
  }

  static Uri uri(Context c, File file) throws Exception {
    File root = new File(c.getFilesDir(), "files").getCanonicalFile();
    if (!file.getCanonicalFile().toPath().startsWith(root.toPath()))
      throw new FileNotFoundException();
    return new Uri.Builder()
        .scheme("content")
        .authority("sbs.astrogate.manager.files")
        .appendPath(root.toPath().relativize(file.getCanonicalFile().toPath()).toString())
        .build();
  }

  private File file(Uri uri) throws FileNotFoundException {
    try {
      File root = new File(getContext().getFilesDir(), "files").getCanonicalFile();
      File f = new File(root, uri.getLastPathSegment()).getCanonicalFile();
      if (!f.toPath().startsWith(root.toPath()) || !f.isFile()) throw new FileNotFoundException();
      return f;
    } catch (Exception e) {
      throw new FileNotFoundException("文件不存在");
    }
  }

  static String mime(String name) {
    int dot = name.lastIndexOf('.');
    String ext = dot < 0 ? "" : name.substring(dot + 1).toLowerCase(java.util.Locale.ROOT);
    String value = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
    return value == null ? "application/octet-stream" : value;
  }

  public String getType(Uri uri) {
    return mime(uri.getLastPathSegment());
  }

  public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
    try {
      File f = file(uri);
      String[] columns =
          projection == null
              ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}
              : projection;
      MatrixCursor c = new MatrixCursor(columns);
      Object[] row = new Object[columns.length];
      for (int i = 0; i < columns.length; i++)
        row[i] =
            columns[i].equals(OpenableColumns.DISPLAY_NAME)
                ? f.getName()
                : columns[i].equals(OpenableColumns.SIZE) ? f.length() : null;
      c.addRow(row);
      return c;
    } catch (Exception e) {
      return null;
    }
  }

  public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
    if (!mode.equals("r")) throw new FileNotFoundException("只读文件");
    return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
  }

  public Uri insert(Uri uri, ContentValues values) {
    throw new UnsupportedOperationException();
  }

  public int delete(Uri uri, String selection, String[] args) {
    throw new UnsupportedOperationException();
  }

  public int update(Uri uri, ContentValues values, String selection, String[] args) {
    throw new UnsupportedOperationException();
  }
}
