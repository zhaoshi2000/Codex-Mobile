package sbs.astrogate.manager;

import android.content.Context;
import android.content.SharedPreferences;
import com.zerotier.sockets.ZeroTierNative;
import java.io.*;
import java.net.*;
import java.util.Set;
import java.util.concurrent.*;
import javax.net.SocketFactory;
import org.json.JSONObject;

/** One app-private userspace node. No VPN or external ZeroTier application. */
final class EmbeddedZeroTier {
  private static EmbeddedZeroTier instance;
  static synchronized EmbeddedZeroTier get(Context context) {
    if (instance == null) instance = new EmbeddedZeroTier(context.getApplicationContext());
    return instance;
  }
  private final File storage;
  private final SharedPreferences preferences;
  private final ScheduledExecutorService monitor = Executors.newSingleThreadScheduledExecutor();
  private final Set<NativeSocket> sockets = ConcurrentHashMap.newKeySet();
  private boolean enabled, ready, joined;
  private long network;
  private String networkID, nodeID = "", address = "", status = "已关闭";

  private EmbeddedZeroTier(Context context) {
    storage = new File(context.getNoBackupFilesDir(), "zerotier");
    preferences = context.getSharedPreferences("embedded-network", Context.MODE_PRIVATE);
    networkID = preferences.getString("network", "");
    monitor.scheduleWithFixedDelay(this::poll, 1, 1, TimeUnit.SECONDS);
    if (preferences.getBoolean("enabled", false)) monitor.execute(() -> {
      try { configure(true, networkID); } catch (Exception e) { synchronized(this) { status=e.getMessage(); } }
    });
  }
  synchronized JSONObject state() throws Exception {
    return new JSONObject().put("enabled",enabled).put("ready",ready).put("networkID",networkID)
        .put("nodeID",nodeID).put("address",address).put("status",status);
  }
  synchronized JSONObject configure(boolean value, String id) throws Exception {
    if (value && !id.matches("[0-9a-fA-F]{16}")) throw new IOException("网络 ID 必须为 16 位十六进制字符");
    if (enabled && value && id.equalsIgnoreCase(networkID)) return state();
    if (enabled) {
      ready=false;
      for (NativeSocket socket : sockets) socket.close();
      long deadline=System.currentTimeMillis()+17000;
      while (!sockets.isEmpty() && System.currentTimeMillis()<deadline) Thread.sleep(25);
      if (!sockets.isEmpty()) throw new IOException("网络连接正在关闭，请稍后重试");
      ZeroTierNative.zts_net_leave(network); ZeroTierNative.zts_node_stop();
      enabled=false; Thread.sleep(1000); joined=false; address="";
    }
    preferences.edit().putBoolean("enabled",false).apply();
    status="已关闭";
    if (value) {
      if (!storage.isDirectory() && !storage.mkdirs()) throw new IOException("无法创建网络身份目录");
      // Same SDK workaround as iOS: stale roots cache can prevent startup.
      File roots=new File(storage,"roots"); if (roots.exists() && !roots.delete()) throw new IOException("无法清理网络缓存");
      check(ZeroTierNative.zts_init_from_storage(storage.getAbsolutePath()));
      check(ZeroTierNative.zts_init_allow_roots_cache(0));
      networkID=id.toLowerCase(java.util.Locale.ROOT); network=Long.parseUnsignedLong(networkID,16);
      check(ZeroTierNative.zts_node_start()); enabled=true; status="正在连接网络…";
      preferences.edit().putString("network",networkID).putBoolean("enabled",true).apply();
    }
    return state();
  }
  private synchronized void poll() {
    if (!enabled) return;
    try {
      long node=ZeroTierNative.zts_node_get_id();if(node!=0) nodeID=String.format("%010x",node);
      boolean online=ZeroTierNative.zts_node_is_online()==1;
      if (!joined) {
        if(!online){ready=false;status="正在连接 ZeroTier…";return;}
        check(ZeroTierNative.zts_net_join(network));joined=true;
      }
      ready=ZeroTierNative.zts_net_transport_is_ready(network)==1;
      address=ready?ZeroTierNative.zts_addr_get_str(network,ZeroTierNative.ZTS_AF_INET):"";
      status=ready?"已连接":online?"等待网络授权，请在网络管理后台授权此节点":"正在重新连接 ZeroTier…";
    } catch (Exception e) {ready=false;status=e.getMessage();}
  }
  private static void check(int code) throws IOException { if(code<0) throw new IOException("ZeroTier 操作失败（"+code+"）"); }
  synchronized void requireReady() throws IOException {if(!enabled||!ready)throw new IOException("请先在服务 → ZeroTier 中启用网络并授权节点");}
  static InetAddress numeric(String host) throws IOException {
    if (host==null || !(host.matches("[0-9.]+")||host.matches("[0-9a-fA-F:]+"))) throw new IOException("请填写 ZeroTier 网络内的 IP 地址");
    return InetAddress.getByName(host);
  }
  SocketFactory factory(String host) throws IOException {
    numeric(host);requireReady();
    return new SocketFactory() {
      public Socket createSocket() {return new NativeSocket(host);}
      public Socket createSocket(String h,int p)throws IOException {Socket s=createSocket();s.connect(new InetSocketAddress(numeric(host),p));return s;}
      public Socket createSocket(InetAddress h,int p)throws IOException {return createSocket(host,p);}
      public Socket createSocket(String h,int p,InetAddress l,int lp)throws IOException {return createSocket(host,p);}
      public Socket createSocket(InetAddress h,int p,InetAddress l,int lp)throws IOException {return createSocket(host,p);}
    };
  }
  Socket connect(String host,int port)throws IOException {return factory(host).createSocket(host,port);}

  private final class NativeSocket extends Socket {
    private final String host;
    private int fd=-1, active=0, timeout=30000, port;
    private boolean closed, connected;
    NativeSocket(String host){this.host=host;}
    @Override public void connect(SocketAddress endpoint)throws IOException {connect(endpoint,10000);}
    @Override public void connect(SocketAddress endpoint,int ms)throws IOException {
      synchronized(EmbeddedZeroTier.this) {
        requireReady();if(sockets.size()>=16)throw new IOException("同时最多打开 16 条直连连接");
        synchronized(this) {
          if(closed||fd>=0)throw new IOException("连接不可重复使用");
          port=((InetSocketAddress)endpoint).getPort();InetAddress ip=numeric(host);
          fd=ZeroTierNative.zts_bsd_socket(ip instanceof Inet6Address?ZeroTierNative.ZTS_AF_INET6:ZeroTierNative.ZTS_AF_INET,ZeroTierNative.ZTS_SOCK_STREAM,0);
          check(fd);sockets.add(this);active++;
        }
      }
      try {
        check(ZeroTierNative.zts_connect(fd,host,port,ms>0?Math.min(ms,15000):10000));
        check(ZeroTierNative.zts_set_send_timeout(fd,15,0));setSoTimeout(timeout);connected=true;
      } catch(IOException e) {close();throw e;} finally {end();}
    }
    private synchronized int begin()throws IOException {if(closed||fd<0)throw new IOException("网络连接已关闭");active++;return fd;}
    private synchronized void end(){active--;if(closed&&active==0)release();}
    private void release(){if(fd>=0){ZeroTierNative.zts_bsd_close(fd);fd=-1;}sockets.remove(this);}
    @Override public synchronized void close(){if(closed)return;closed=true;if(fd>=0)ZeroTierNative.zts_bsd_shutdown(fd,2);if(active==0)release();}
    @Override public synchronized boolean isClosed(){return closed;}
    @Override public boolean isConnected(){return connected&&!closed;}
    @Override public InetAddress getInetAddress(){try{return numeric(host);}catch(IOException e){return null;}}
    @Override public int getPort(){return port;}
    @Override public InetAddress getLocalAddress(){try{return numeric(address);}catch(IOException e){return InetAddress.getLoopbackAddress();}}
    @Override public synchronized void setSoTimeout(int ms)throws SocketException {timeout=ms;if(fd>=0&&ZeroTierNative.zts_set_recv_timeout(fd,ms/1000,(ms%1000)*1000)<0)throw new SocketException("设置超时失败");}
    @Override public synchronized int getSoTimeout(){return timeout;}
    @Override public void shutdownOutput()throws IOException {int f=begin();try{check(ZeroTierNative.zts_bsd_shutdown(f,1));}finally{end();}}
    @Override public InputStream getInputStream(){return new InputStream(){
      public int read()throws IOException {byte[] b=new byte[1];int n=read(b,0,1);return n<0?-1:b[0]&255;}
      public int read(byte[] b,int off,int len)throws IOException {if(len==0)return 0;int f=begin();try{int n=ZeroTierNative.zts_bsd_read_offset(f,b,off,len);check(n);return n==0?-1:n;}finally{end();}}
      public void close(){NativeSocket.this.close();}
    };}
    @Override public OutputStream getOutputStream(){return new OutputStream(){
      public void write(int b)throws IOException{write(new byte[]{(byte)b});}
      public void write(byte[] b,int off,int len)throws IOException {int f=begin();try{while(len>0){int n=ZeroTierNative.zts_bsd_write_offset(f,b,off,len);if(n<=0)throw new IOException("ZeroTier 写入失败（"+n+"）");off+=n;len-=n;}}finally{end();}}
      public void close(){NativeSocket.this.close();}
    };}
  }
}
