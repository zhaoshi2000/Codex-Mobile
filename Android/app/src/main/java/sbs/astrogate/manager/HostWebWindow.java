package sbs.astrogate.manager;

import android.app.*;
import android.graphics.Color;
import android.webkit.*;
import android.widget.*;
import androidx.webkit.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.JSONObject;

/** Separate unprivileged WebView: remote pages never receive the Native bridge. */
final class HostWebWindow implements AutoCloseable {
  private HostWebProxy proxy;
  private Dialog dialog;
  private WebView web;
  private volatile boolean closed;
  private final Activity activity;
  HostWebWindow(Activity activity,CodexClient codex,EmbeddedZeroTier node,String address,String directIP)throws Exception {
    this.activity=activity;
    if(!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)||!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE_REVERSE_BYPASS))throw new IOException("请先更新 Android System WebView，再打开主机网页服务");
    URI url=new URI(address);int port=url.getPort()>0?url.getPort():"https".equals(url.getScheme())?443:80;
    if(directIP!=null){node.requireReady();EmbeddedZeroTier.numeric(directIP);}
    proxy=new HostWebProxy(url,()->{
      if(directIP!=null){java.net.Socket socket=node.connect(directIP,port);return new HostWebProxy.Pipe(){public InputStream input()throws Exception{return socket.getInputStream();}public OutputStream output()throws Exception{return socket.getOutputStream();}public void close(){try{socket.close();}catch(Exception ignored){}}};}
      return new RelayPipe(codex,port);
    });
    activity.runOnUiThread(()->{
      if(closed)return;
      dialog=new Dialog(activity,android.R.style.Theme_DeviceDefault_NoActionBar);
      LinearLayout layout=new LinearLayout(activity);layout.setOrientation(LinearLayout.VERTICAL);
      Button close=new Button(activity);close.setText((directIP==null?"服务器中转":"ZeroTier 直连")+" · 关闭");close.setOnClickListener(v->close());layout.addView(close);
      TextView status=new TextView(activity);status.setText("正在连接主机…");status.setPadding(16,4,16,8);layout.addView(status);
      web=new WebView(activity);web.getSettings().setJavaScriptEnabled(true);web.getSettings().setDomStorageEnabled(true);web.getSettings().setAllowFileAccess(false);web.getSettings().setAllowContentAccess(false);web.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
      web.setWebViewClient(new WebViewClient(){
        public void onReceivedHttpAuthRequest(WebView v,HttpAuthHandler handler,String host,String realm){if(proxy!=null&&proxy.realm.equals(realm))handler.proceed("astrogate",proxy.password);else handler.cancel();}
        public void onPageFinished(WebView v,String u){status.setText(u);}
        public void onReceivedError(WebView v,WebResourceRequest r,WebResourceError e){if(r.isForMainFrame())status.setText("连接失败："+e.getDescription()+"。请检查电脑服务端口和网络授权。");}
        public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest r){String scheme=r.getUrl().getScheme();return !"http".equals(scheme)&&!"https".equals(scheme);}
      });
      layout.addView(web,new LinearLayout.LayoutParams(-1,0,1));dialog.setContentView(layout);dialog.setOnDismissListener(d->close());dialog.show();dialog.getWindow().setLayout(-1,-1);
      // Subtractive rules must precede the explicit host match when reversed.
      ProxyConfig config=new ProxyConfig.Builder().addProxyRule("http://127.0.0.1:"+proxy.port()).removeImplicitRules().addBypassRule(url.getHost()).setReverseBypassEnabled(true).build();
      ProxyController.getInstance().setProxyOverride(config,activity::runOnUiThread,()->{if(!closed)web.loadUrl(address);});
    });
  }
  public void close(){if(closed)return;closed=true;if(proxy!=null)proxy.close();activity.runOnUiThread(()->{ProxyController.getInstance().clearProxyOverride(activity::runOnUiThread,()->{});if(web!=null){web.stopLoading();web.destroy();web=null;}if(dialog!=null&&dialog.isShowing())dialog.dismiss();});}
  private static final class RelayPipe implements HostWebProxy.Pipe {
    final CodexClient codex;final String id;volatile boolean closed;
    RelayPipe(CodexClient c,int port)throws Exception {codex=c;id=c.request("networkOpen",new JSONObject().put("host","127.0.0.1").put("port",port)).getString("id");}
    public InputStream input(){return new InputStream(){byte[] buffer=new byte[0];int offset;boolean eof;
      public int read()throws IOException{byte[] b=new byte[1];int n=read(b);return n<0?-1:b[0]&255;}
      public int read(byte[] b,int off,int len)throws IOException {if(len==0)return 0;try{while(offset==buffer.length){if(eof||closed)return -1;JSONObject r=codex.request("networkRead",new JSONObject().put("id",id));buffer=Base64.getDecoder().decode(r.optString("data"));offset=0;eof=r.optBoolean("eof");if(buffer.length==0&&!eof)Thread.sleep(80);}int n=Math.min(len,buffer.length-offset);System.arraycopy(buffer,offset,b,off,n);offset+=n;return n;}catch(Exception e){throw new IOException("主机网页连接中断",e);}}
    };}
    public OutputStream output(){return new OutputStream(){public void write(int b)throws IOException{write(new byte[]{(byte)b});}public void write(byte[] b,int off,int len)throws IOException {try{for(int end=off+len;off<end;){int n=Math.min(32768,end-off);codex.request("networkWrite",new JSONObject().put("id",id).put("data",Base64.getEncoder().encodeToString(Arrays.copyOfRange(b,off,off+n))));off+=n;}}catch(Exception e){throw new IOException("主机网页发送失败",e);}}};}
    public void close(){if(closed)return;closed=true;CompletableFuture.runAsync(()->{try{codex.request("networkClose",new JSONObject().put("id",id));}catch(Exception ignored){}});}
  }
}
