package sbs.astrogate.manager;
import org.junit.Test;
import static org.junit.Assert.*;
import java.net.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public class HostWebProxyTest {
  private static String exchange(HostWebProxy proxy,String request)throws Exception {
    try(Socket socket=new Socket("127.0.0.1",proxy.port())){socket.setSoTimeout(5000);socket.getOutputStream().write(request.getBytes(StandardCharsets.US_ASCII));return new String(socket.getInputStream().readAllBytes(),StandardCharsets.US_ASCII);}
  }
  private static String auth(HostWebProxy proxy){return "Proxy-Authorization: Basic "+Base64.getEncoder().encodeToString(("astrogate:"+proxy.password).getBytes(StandardCharsets.UTF_8))+"\r\n";}
  @Test public void requiresSecretBeforeOpeningAnything()throws Exception {
    AtomicInteger opens=new AtomicInteger();
    try(HostWebProxy proxy=new HostWebProxy(new URI("http://localhost:3000"),()->{opens.incrementAndGet();throw new IOException();})){
      assertTrue(exchange(proxy,"GET http://localhost:3000/ HTTP/1.1\r\nHost: localhost\r\n\r\n").startsWith("HTTP/1.1 407"));
      assertTrue(exchange(proxy,"GET http://evil.invalid:3000/ HTTP/1.1\r\n"+auth(proxy)+"\r\n").startsWith("HTTP/1.1 403"));
      assertTrue(exchange(proxy,"CONNECT localhost:22 HTTP/1.1\r\n"+auth(proxy)+"\r\n").startsWith("HTTP/1.1 403"));
      assertEquals(0,opens.get());
    }
  }
  @Test public void preservesPathQueryAndPostBodyWithoutLeakingProxySecret()throws Exception {
    try(ServerSocket server=new ServerSocket(0,1,InetAddress.getLoopbackAddress())){
      CompletableFuture<String> received=CompletableFuture.supplyAsync(()->{try(Socket socket=server.accept()){
        socket.setSoTimeout(5000);InputStream in=socket.getInputStream();StringBuilder request=new StringBuilder();for(String l;!(l=HostWebProxy.line(in)).isEmpty();)request.append(l).append('\n');byte[] body=in.readNBytes(4);request.append(new String(body,StandardCharsets.UTF_8));socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nPASS".getBytes(StandardCharsets.US_ASCII));return request.toString();
      }catch(Exception e){throw new RuntimeException(e);}});
      try(HostWebProxy proxy=new HostWebProxy(new URI("http://localhost:"+server.getLocalPort()),()->{
        Socket socket=new Socket("127.0.0.1",server.getLocalPort());return new HostWebProxy.Pipe(){public InputStream input()throws Exception{return socket.getInputStream();}public OutputStream output()throws Exception{return socket.getOutputStream();}public void close(){try{socket.close();}catch(Exception ignored){}}};
      })){
        String result=exchange(proxy,"POST http://localhost:"+server.getLocalPort()+"/a?q=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n"+auth(proxy)+"\r\nDATA");
        assertTrue(result.endsWith("PASS"));String request=received.get(5,TimeUnit.SECONDS);assertTrue(request.startsWith("POST /a?q=1 HTTP/1.1\n"));assertTrue(request.endsWith("DATA"));assertFalse(request.contains("Proxy-Authorization"));assertFalse(request.contains(proxy.password));
      }
    }
  }
}
