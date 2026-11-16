package sbs.astrogate.manager;

import android.app.Activity;
import android.content.Intent;
import android.hardware.Camera;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import java.util.*;

@SuppressWarnings("deprecation")
public final class ScanActivity extends Activity
    implements SurfaceHolder.Callback, Camera.PreviewCallback {
  private Camera camera;
  private boolean finished;
  private long last;

  @Override
  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    LinearLayout layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    layout.setBackgroundColor(0xff121820);
    TextView help = new TextView(this);
    help.setText("扫描电脑连接程序上的配对二维码\n返回可改为粘贴配对链接");
    help.setTextColor(-1);
    help.setTextSize(18);
    help.setPadding(24, 64, 24, 24);
    layout.addView(help);
    SurfaceView preview = new SurfaceView(this);
    layout.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1));
    preview.getHolder().addCallback(this);
    Button back = new Button(this);
    back.setText("取消");
    back.setOnClickListener(v -> finish());
    layout.addView(back);
    setContentView(layout);
  }

  public void surfaceCreated(SurfaceHolder holder) {
    try {
      camera = Camera.open();
      Camera.Parameters p = camera.getParameters();
      if (p.getSupportedFocusModes().contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE))
        p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
      List<Camera.Size> sizes = p.getSupportedPreviewSizes();
      Camera.Size size =
          sizes.stream()
              .filter(x -> x.width <= 1280)
              .max(Comparator.comparingInt(x -> x.width * x.height))
              .orElse(sizes.get(0));
      p.setPreviewSize(size.width, size.height);
      camera.setParameters(p);
      camera.setDisplayOrientation(90);
      camera.setPreviewDisplay(holder);
      camera.setPreviewCallback(this);
      camera.startPreview();
    } catch (Exception e) {
      Toast.makeText(this, "相机无法打开，请粘贴配对链接", Toast.LENGTH_LONG).show();
      finish();
    }
  }

  public void surfaceChanged(SurfaceHolder h, int f, int w, int ht) {}

  public void surfaceDestroyed(SurfaceHolder h) {
    release();
  }

  private void release() {
    if (camera != null) {
      camera.setPreviewCallback(null);
      camera.stopPreview();
      camera.release();
      camera = null;
    }
  }

  @Override
  protected void onPause() {
    release();
    super.onPause();
  }

  public void onPreviewFrame(byte[] bytes, Camera cam) {
    if (finished || System.currentTimeMillis() - last < 350) return;
    last = System.currentTimeMillis();
    try {
      Camera.Size s = cam.getParameters().getPreviewSize();
      PlanarYUVLuminanceSource source =
          new PlanarYUVLuminanceSource(bytes, s.width, s.height, 0, 0, s.width, s.height, false);
      Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
      hints.put(DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
      Result r =
          new MultiFormatReader().decode(new BinaryBitmap(new HybridBinarizer(source)), hints);
      if (!r.getText().startsWith("ifilecodex://pair")) return;
      finished = true;
      setResult(RESULT_OK, new Intent().putExtra("qr", r.getText()));
      finish();
    } catch (Exception ignored) {
    }
  }
}
