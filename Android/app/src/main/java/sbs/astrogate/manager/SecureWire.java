package sbs.astrogate.manager;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.bouncycastle.math.ec.rfc7748.X25519;
import org.json.JSONObject;

public final class SecureWire {
  private final byte[] key;
  private final String host, sid;
  private long sent, received;

  public static byte[] identity() {
    byte[] key = new byte[32];
    X25519.generatePrivateKey(new SecureRandom(), key);
    return key;
  }

  public static byte[] publicKey(byte[] privateKey) {
    byte[] out = new byte[32];
    X25519.generatePublicKey(privateKey, 0, out, 0);
    return out;
  }

  public static String b64(byte[] b) {
    return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
  }

  public static byte[] un64(String b) {
    return Base64.getUrlDecoder().decode(b);
  }

  public SecureWire(byte[] secret, byte[] peer, String host, String sid) throws Exception {
    if (secret.length != 32 || peer.length != 32) throw new Exception("电脑身份密钥无效");
    this.host = host;
    this.sid = sid;
    byte[] shared = new byte[32];
    if (!X25519.calculateAgreement(secret, 0, peer, 0, shared, 0)) throw new Exception("密钥协商失败");
    byte[] salt =
        MessageDigest.getInstance("SHA-256")
            .digest((host + "|" + sid).getBytes(StandardCharsets.UTF_8));
    Mac hmac = Mac.getInstance("HmacSHA256");
    hmac.init(new SecretKeySpec(salt, "HmacSHA256"));
    byte[] prk = hmac.doFinal(shared);
    hmac.init(new SecretKeySpec(prk, "HmacSHA256"));
    key = hmac.doFinal("ifile-connect-v1\u0001".getBytes(StandardCharsets.UTF_8));
  }

  private byte[] aad(String direction, long seq) {
    return (host + "|" + sid + "|" + direction + "|" + seq).getBytes(StandardCharsets.UTF_8);
  }

  public synchronized JSONObject seal(JSONObject value) throws Exception {
    byte[] nonce = new byte[12];
    new SecureRandom().nextBytes(nonce);
    long seq = ++sent;
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(
        Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
    cipher.updateAAD(aad("c2h", seq));
    return new JSONObject()
        .put("seq", seq)
        .put("nonce", Base64.getEncoder().encodeToString(nonce))
        .put(
            "body",
            Base64.getEncoder()
                .encodeToString(cipher.doFinal(value.toString().getBytes(StandardCharsets.UTF_8))));
  }

  public synchronized JSONObject open(JSONObject box) throws Exception {
    long seq = box.getLong("seq");
    if (seq != received + 1) throw new Exception("消息序号不连续，请重新连接");
    byte[] nonce = Base64.getDecoder().decode(box.getString("nonce")),
        body = Base64.getDecoder().decode(box.getString("body"));
    if (nonce.length != 12 || body.length < 16 || body.length > 900000)
      throw new Exception("加密消息格式错误");
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(
        Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
    cipher.updateAAD(aad("h2c", seq));
    JSONObject value = new JSONObject(new String(cipher.doFinal(body), StandardCharsets.UTF_8));
    received = seq;
    return value;
  }
}
