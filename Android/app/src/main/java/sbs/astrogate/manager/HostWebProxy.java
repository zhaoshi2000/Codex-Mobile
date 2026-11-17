package sbs.astrogate.manager;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Authenticated, page-scoped HTTP/CONNECT proxy; never forwards other origins. */
final class HostWebProxy implements AutoCloseable {
  interface Pipe extends AutoCloseable {InputStream input() throws Exception;OutputStream output() throws Exception;void close();}
  interface Connector {Pipe open() throws Exception;}
  final String password=UUID.randomUUID().toString(), realm="AstroGate-"+UUID.randomUUID();
  private final ServerSocket listener;
  private final String host;
  private final int targetPort;
  private final Connector connector;
  private final ExecutorService workers=Executors.newCachedThreadPool();
  private final Set<Socket> clients=ConcurrentHashMap.newKeySet();
  private final Set<Pipe> pipes=ConcurrentHashMap.newKeySet();
  private volatile boolean closed;
  HostWebProxy(URI url,Connector connector)throws IOException {
    host=url.getHost();targetPort=url.getPort()>0?url.getPort():"https".equals(url.getScheme())?443:80;
    if(host==null||url.getUserInfo()!=null||!("http".equals(url.getScheme())||"https".equals(url.getScheme()))||targetPort>65535)throw new IOException("网页地址无效");
    this.connector=connector;
    listener=new ServerSocket(0,8,InetAddress.getByName("127.0.0.1"));
    workers.execute(()->{while(!closed)try{Socket c=listener.accept();c.setSoTimeout(15000);if(clients.size()>=8){c.close();continue;}clients.add(c);workers.execute(()->handle(c));}catch(IOException e){if(!closed)close();}});
  }
  int port(){return listener.getLocalPort();}
  static String line(InputStream in)throws IOException {
    ByteArrayOutputStream b=new ByteArrayOutputStream();int previous=-1;
    for(int i=0;i<32768;i++){int c=in.read();if(c<0)throw new EOFException();if(previous==13&&c==10){byte[] bytes=b.toByteArray();return new String(bytes,0,bytes.length-1,StandardCharsets.ISO_8859_1);}b.write(c);previous=c;}
    throw new IOException("HTTP 请求头过长");
  }
  private void handle(Socket client){
    Pipe remote=null;
    try {
      InputStream in=client.getInputStream();OutputStream out=client.getOutputStream();
      String[] first=line(in).split(" ",3);if(first.length!=3)throw new IOException("Invalid request");
      ArrayList<String> headers=new ArrayList<>();String auth="";boolean upgrade=false;int size=0;
      for(String h;(h=line(in)).length()>0;){size+=h.length();if(size>32768)throw new IOException("Headers too long");String lower=h.toLowerCase(Locale.ROOT);if(lower.startsWith("proxy-authorization:"))auth=h.substring(h.indexOf(':')+1).trim();else if(!lower.startsWith("proxy-connection:")){headers.add(h);if(lower.startsWith("upgrade:"))upgrade=true;}}
      String expected="Basic "+Base64.getEncoder().encodeToString(("astrogate:"+password).getBytes(StandardCharsets.UTF_8));
      if(!java.security.MessageDigest.isEqual(auth.getBytes(StandardCharsets.UTF_8),expected.getBytes(StandardCharsets.UTF_8))){out.write(("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\""+realm+"\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.ISO_8859_1));return;}
      boolean connect=first[0].equals("CONNECT");URI target=new URI(connect?"https://"+first[1]:first[1]);
      int requested=target.getPort()>0?target.getPort():"https".equals(target.getScheme())?443:80;
      if(!host.equalsIgnoreCase(target.getHost())||requested!=targetPort||target.getUserInfo()!=null){out.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.US_ASCII));return;}
      remote=connector.open();pipes.add(remote);if(closed)return;client.setSoTimeout(120000);
      Pipe pipe=remote;
      if(connect)out.write("HTTP/1.1 200 Connection Established\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
      else {
        String path=target.getRawPath();if(path==null||path.isEmpty())path="/";if(target.getRawQuery()!=null)path+="?"+target.getRawQuery();
        StringBuilder request=new StringBuilder(first[0]+" "+path+" HTTP/1.1\r\n");
        for(String h:headers)if(upgrade||!h.toLowerCase(Locale.ROOT).startsWith("connection:"))request.append(h).append("\r\n");
        if(!upgrade)request.append("Connection: close\r\n");request.append("\r\n");pipe.output().write(request.toString().getBytes(StandardCharsets.ISO_8859_1));
      }
      workers.execute(()->{try{copy(in,pipe.output());}catch(Exception ignored){}finally{pipe.close();try{client.close();}catch(IOException ignored){}}});
      copy(pipe.input(),out);
    }catch(Exception ignored){}finally{if(remote!=null){remote.close();pipes.remove(remote);}clients.remove(client);try{client.close();}catch(IOException ignored){}}
  }
  private static void copy(InputStream in,OutputStream out)throws IOException {byte[] b=new byte[32768];for(int n;(n=in.read(b))>=0;){if(n>0){out.write(b,0,n);out.flush();}}}
  public void close(){if(closed)return;closed=true;try{listener.close();}catch(IOException ignored){}for(Socket c:clients)try{c.close();}catch(IOException ignored){}for(Pipe p:pipes)p.close();workers.shutdownNow();}
}
