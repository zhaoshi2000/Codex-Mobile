package sbs.astrogate.manager;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

final class Vault {
  private final Context context;
  private final SecretKey key;

  Vault(Context context) throws Exception {
    this.context = context;
    KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
    ks.load(null);
    if (!ks.containsAlias("astrogate.v1")) {
      KeyGenerator gen = KeyGenerator.getInstance("AES", "AndroidKeyStore");
      gen.init(
          new KeyGenParameterSpec.Builder(
                  "astrogate.v1", KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
              .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
              .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
              .build());
      gen.generateKey();
    }
    key = (SecretKey) ks.getKey("astrogate.v1", null);
  }

  synchronized JSONObject load() throws Exception {
    String saved = context.getSharedPreferences("vault", 0).getString("data", null);
    if (saved == null) return new JSONObject();
    byte[] data = Base64.decode(saved, Base64.DEFAULT);
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, data, 0, 12));
    return new JSONObject(
        new String(
            cipher.doFinal(data, 12, data.length - 12), java.nio.charset.StandardCharsets.UTF_8));
  }

  synchronized void save(JSONObject value) throws Exception {
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, key);
    byte[]
        body = cipher.doFinal(value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)),
        iv = cipher.getIV(),
        all = new byte[iv.length + body.length];
    System.arraycopy(iv, 0, all, 0, iv.length);
    System.arraycopy(body, 0, all, iv.length, body.length);
    if (!context
        .getSharedPreferences("vault", 0)
        .edit()
        .putString("data", Base64.encodeToString(all, Base64.NO_WRAP))
        .commit()) throw new Exception("保存失败");
  }
}
