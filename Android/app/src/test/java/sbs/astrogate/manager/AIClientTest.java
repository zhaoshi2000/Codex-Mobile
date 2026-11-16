package sbs.astrogate.manager;

import static org.junit.Assert.*;

import java.util.concurrent.atomic.AtomicReference;
import okhttp3.*;
import okhttp3.mockwebserver.*;
import okhttp3.tls.*;
import org.json.*;
import org.junit.*;

public class AIClientTest {
  MockWebServer server;
  AIClient client;
  JSONObject config;

  @Before
  public void setup() throws Exception {
    HeldCertificate certificate =
        new HeldCertificate.Builder()
            .commonName("localhost")
            .addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1")
            .build();
    HandshakeCertificates
        host = new HandshakeCertificates.Builder().heldCertificate(certificate).build(),
        phone =
            new HandshakeCertificates.Builder()
                .addTrustedCertificate(certificate.certificate())
                .build();
    server = new MockWebServer();
    server.useHttps(host.sslSocketFactory(), false);
    server.start();
    client =
        new AIClient(
            new OkHttpClient.Builder()
                .sslSocketFactory(phone.sslSocketFactory(), phone.trustManager())
                .followRedirects(false)
                .build());
    config =
        new JSONObject()
            .put("address", server.url("/v1").toString())
            .put("apiKey", "test-fixture-key")
            .put("model", "test-model");
  }

  @After
  public void close() throws Exception {
    server.shutdown();
  }

  @Test
  public void modelsUseAuthorizationAndDeduplicate() throws Exception {
    server.enqueue(
        new MockResponse()
            .setHeader("Content-Type", "application/json")
            .setBody("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"},{\"id\":\"a\"}]}"));
    JSONArray models = client.models(config);
    assertEquals(2, models.length());
    assertEquals("a", models.getString(0));
    RecordedRequest request = server.takeRequest();
    assertEquals("/v1/models", request.getPath());
    assertEquals("Bearer test-fixture-key", request.getHeader("Authorization"));
  }

  @Test
  public void streamingTextAndFinishedResponse() throws Exception {
    server.enqueue(
        new MockResponse()
            .setHeader("Content-Type", "text/event-stream")
            .setBody(
                "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\n\n"
                    + "data:"
                    + " {\"choices\":[{\"delta\":{\"content\":\"，安卓\"},\"finish_reason\":\"stop\"}]}\n\n"
                    + "data: [DONE]\n\n"));
    AtomicReference<String> text = new AtomicReference<>();
    JSONObject message =
        client.complete(
            config,
            new JSONArray().put(new JSONObject().put("role", "user").put("content", "测试")),
            text::set);
    assertEquals("你好，安卓", message.getString("content"));
    assertEquals("你好，安卓", text.get());
    assertFalse(message.has("tool_calls"));
    assertEquals("/v1/chat/completions", server.takeRequest().getPath());
  }

  @Test
  public void errorsDoNotEchoSecretsOrRemoteBody() throws Exception {
    server.enqueue(new MockResponse().setResponseCode(401).setBody("untrusted secret body"));
    Exception e = assertThrows(Exception.class, () -> client.models(config));
    assertTrue(e.getMessage().contains("401"));
    assertFalse(e.getMessage().contains("secret"));
  }

  @Test
  public void truncatedStreamCannotProduceExecutableCommands() throws Exception {
    server.enqueue(
        new MockResponse()
            .setHeader("Content-Type", "text/event-stream")
            .setBody("data: {\"choices\":[{\"delta\":{\"content\":\"unfinished\"}}]}\n\n"));
    assertTrue(
        assertThrows(Exception.class, () -> client.complete(config, new JSONArray(), text -> {}))
            .getMessage()
            .contains("输出连接中断"));
  }
}
