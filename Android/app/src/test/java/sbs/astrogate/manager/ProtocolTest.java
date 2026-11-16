package sbs.astrogate.manager;

import static org.junit.Assert.*;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.spec.*;
import org.json.*;
import org.junit.Test;

public class ProtocolTest {
  JSONObject fixture() throws Exception {
    return new JSONObject(
        new String(
            getClass().getResourceAsStream("/wire.json").readAllBytes(), StandardCharsets.UTF_8));
  }

  SecureWire wire(JSONObject f) throws Exception {
    return new SecureWire(
        SecureWire.un64(f.getString("phoneSecret")),
        SecureWire.un64(f.getString("hostPublic")),
        f.getString("hostId"),
        f.getString("sid"));
  }

  @Test
  public void nodeHostToAndroidAndReplayProtection() throws Exception {
    JSONObject f = fixture();
    SecureWire w = wire(f);
    assertEquals(
        f.getString("phonePublic"),
        SecureWire.b64(SecureWire.publicKey(SecureWire.un64(f.getString("phoneSecret")))));
    JSONObject first = f.getJSONArray("boxes").getJSONObject(0);
    assertEquals("跨端加密测试", w.open(first).getString("text"));
    assertThrows(Exception.class, () -> w.open(first));
    assertTrue(
        w.open(f.getJSONArray("boxes").getJSONObject(1))
            .getJSONObject("result")
            .getBoolean("alive"));
  }

  @Test
  public void androidToNodeCompatibleKeyAndAAD() throws Exception {
    JSONObject f = fixture(), box = wire(f).seal(new JSONObject().put("method", "history"));
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(
        Cipher.DECRYPT_MODE,
        new SecretKeySpec(Base64.getDecoder().decode(f.getString("key")), "AES"),
        new GCMParameterSpec(128, Base64.getDecoder().decode(box.getString("nonce"))));
    cipher.updateAAD(
        (f.getString("hostId") + "|" + f.getString("sid") + "|c2h|1")
            .getBytes(StandardCharsets.UTF_8));
    assertEquals(
        "history",
        new JSONObject(
                new String(
                    cipher.doFinal(Base64.getDecoder().decode(box.getString("body"))),
                    StandardCharsets.UTF_8))
            .getString("method"));
  }

  @Test
  public void corruptedCiphertextDoesNotAdvanceSequence() throws Exception {
    JSONObject f = fixture();
    SecureWire w = wire(f);
    JSONObject original = f.getJSONArray("boxes").getJSONObject(0),
        bad = new JSONObject(original.toString());
    byte[] body = Base64.getDecoder().decode(bad.getString("body"));
    body[0] ^= 1;
    bad.put("body", Base64.getEncoder().encodeToString(body));
    assertThrows(Exception.class, () -> w.open(bad));
    assertEquals("ready", w.open(original).getString("event"));
  }

  @Test
  public void rejectSkippedSequenceAndInvalidPublicKey() throws Exception {
    JSONObject f = fixture();
    assertThrows(Exception.class, () -> wire(f).open(f.getJSONArray("boxes").getJSONObject(1)));
    assertThrows(Exception.class, () -> new SecureWire(new byte[32], new byte[32], "h", "s"));
  }

  @Test
  public void apiEndpointNormalizationAndCredentialLeakPrevention() throws Exception {
    assertEquals(
        "https://example.com/v1/models",
        AIClient.endpoint("https://example.com/v1/", "models").toString());
    assertEquals(
        "https://example.com/v1/models",
        AIClient.endpoint("https://example.com/v1/chat/completions", "models").toString());
    assertThrows(Exception.class, () -> AIClient.endpoint("http://example.com/v1", "models"));
    assertThrows(
        Exception.class, () -> AIClient.endpoint("https://secret@example.com/v1", "models"));
    assertThrows(
        Exception.class, () -> AIClient.endpoint("https://example.com/v1?key=secret", "models"));
  }
}
