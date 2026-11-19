package com.shangweiqiu.rijian;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.webkit.*;
import android.widget.Toast;
import android.widget.FrameLayout;
import android.view.WindowInsets;
import android.graphics.Insets;
import java.io.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

public class MainActivity extends Activity {
    public static volatile boolean visible=false;
    private WebView webView;
    private ValueCallback<Uri[]> fileCallback;
    private String pendingBackup;
    private String musicTransfer="";
    private long musicReceived=0;
    private static final String ORIGIN = "https://appassets.androidplatform.net/web/";
    private static final int PICK_FILE = 10;
    private static final int SAVE_BACKUP = 11;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        webView = new WebView(this);
        webView.setBackgroundColor(0xfff7f5ef);
        FrameLayout content = new FrameLayout(this);
        content.setBackgroundColor(0xfff7f5ef);
        content.addView(webView, new FrameLayout.LayoutParams(-1, -1));
        content.setOnApplyWindowInsetsListener((view, insets) -> {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                Insets safe = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        setContentView(content);
        content.requestApplyInsets();
        WebSettings settings = webView.getSettings();
        settings.setTextZoom(100);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setBuiltInZoomControls(false);
        settings.setDisplayZoomControls(false);
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true);
        settings.setMediaPlaybackRequiresUserGesture(true);
        webView.addJavascriptInterface(new Bridge(), "RijianAndroid");
        webView.setWebViewClient(new WebViewClient() {
            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if (!"appassets.androidplatform.net".equals(uri.getHost())) return null;
                String path = uri.getPath();
                if (path == null || !path.startsWith("/web/") || path.contains("..") || path.contains("\\")) return missing();
                try {
                    String mime = path.endsWith(".js") ? "application/javascript" : path.endsWith(".css") ? "text/css" : path.endsWith(".png") ? "image/png" : path.endsWith(".json") ? "application/json" : "text/html";
                    return new WebResourceResponse(mime,"UTF-8",getAssets().open(path.substring(1)));
                } catch (IOException error) { return missing(); }
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if ("appassets.androidplatform.net".equals(request.getUrl().getHost())) return false;
                try { startActivity(new Intent(Intent.ACTION_VIEW,request.getUrl())); }
                catch (Exception error) { showMessage("暂时无法打开链接"); }
                return true;
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                try {
                    Intent intent = params.createIntent();
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                    startActivityForResult(intent,PICK_FILE);
                } catch (Exception error) { fileCallback.onReceiveValue(null); fileCallback=null; showMessage("无法打开文件选择器"); }
                return true;
            }
            @Override public boolean onJsAlert(WebView view,String url,String message,JsResult result) {
                new android.app.AlertDialog.Builder(MainActivity.this).setMessage(message).setPositiveButton("确定",(dialog,which)->result.confirm()).setOnCancelListener(dialog->result.cancel()).show();
                return true;
            }
            @Override public boolean onJsConfirm(WebView view,String url,String message,JsResult result) {
                new android.app.AlertDialog.Builder(MainActivity.this).setMessage(message).setPositiveButton("确定",(dialog,which)->result.confirm()).setNegativeButton("取消",(dialog,which)->result.cancel()).setOnCancelListener(dialog->result.cancel()).show();
                return true;
            }
        });
        ReminderScheduler.initialize(this);
        ReminderScheduler.restore(this);
        webView.loadUrl(ORIGIN+"index.html");
    }
    private WebResourceResponse missing() {
        return new WebResourceResponse("text/plain","UTF-8",404,"Not Found",null,new ByteArrayInputStream(new byte[0]));
    }
    private void showMessage(String message) { Toast.makeText(this,message,Toast.LENGTH_LONG).show(); }
    private final class Bridge {
        @JavascriptInterface public void send(String json) {
            runOnUiThread(() -> {
                try {
                    JSONObject message = new JSONObject(json);
                    String action=message.getString("action");
                    if (action.equals("status")) { publishStatus();return; }
                    if (action.equals("requestReminders")) {
                        if (android.os.Build.VERSION.SDK_INT>=33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},20);
                        else publishStatus();
                        return;
                    }
                    if (action.equals("exactAlarmSettings")) {
                        if (android.os.Build.VERSION.SDK_INT>=31 && !ReminderScheduler.exactAllowed(MainActivity.this)) startActivity(new Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,Uri.parse("package:"+getPackageName())));
                        else publishStatus();
                        return;
                    }
                    if (action.equals("sync")) { ReminderScheduler.sync(MainActivity.this,message.getJSONArray("requests"));publishStatus();return; }
                    if (action.equals("playAlarm")) { ReminderScheduler.startSound(MainActivity.this,message.optString("key"),message.optString("title","日子提醒"));publishStatus();return; }
                    if (action.equals("stopAlarm")) { stopService(new Intent(MainActivity.this,AlarmSoundService.class));publishStatus();return; }
                    if (action.equals("removeMusic")) { new File(getFilesDir(),"reminder-music").delete();return; }
                    if (action.equals("musicChunk")) {
                        String failure=null;
                        try {
                            int offset=message.getInt("offset"),total=message.getInt("total");
                            if(total<=0||total>200*1024*1024)throw new IOException("请选择 200MB 以内的音乐");
                            String transfer=message.getString("transfer");
                            byte[] bytes=android.util.Base64.decode(message.getString("data"),android.util.Base64.DEFAULT);
                            if(bytes.length>1024*1024)throw new IOException("音乐分段过大");
                            File temp=new File(getFilesDir(),"reminder-music.tmp");
                            if(offset==0){musicTransfer=transfer;musicReceived=0;try(FileOutputStream output=new FileOutputStream(temp)){}}
                            if(!transfer.equals(musicTransfer)||offset!=musicReceived||offset+bytes.length>total)throw new IOException("音乐传输中断，请重试");
                            try(FileOutputStream output=new FileOutputStream(temp,true)){output.write(bytes);}
                            musicReceived+=bytes.length;
                            if(message.optBoolean("final")){
                                if(musicReceived!=total)throw new IOException("音乐文件不完整");
                                android.media.MediaPlayer validator=new android.media.MediaPlayer();
                                try{validator.setDataSource(temp.getAbsolutePath());validator.prepare();}finally{validator.release();}
                                if(!temp.renameTo(new File(getFilesDir(),"reminder-music")))throw new IOException("音乐保存失败");
                            }
                        }catch(Exception error){failure=error.getMessage();}
                        webView.evaluateJavascript("window.rijianNativeMusicResult?.("+JSONObject.quote(message.getString("callback"))+","+(failure==null?"null":JSONObject.quote(failure))+")",null);
                        return;
                    }
                    if (action.equals("music")) {
                        byte[] bytes=android.util.Base64.decode(message.getString("data"),android.util.Base64.DEFAULT);
                        if(bytes.length>200*1024*1024)throw new IOException("Music too large");
                        File temporary=new File(getFilesDir(),"reminder-music.tmp");
                        try(FileOutputStream output=new FileOutputStream(temporary)){output.write(bytes);}
                        android.media.MediaPlayer validator=new android.media.MediaPlayer();
                        try {validator.setDataSource(temporary.getAbsolutePath());validator.prepare();}finally{validator.release();}
                        if(!temporary.renameTo(new File(getFilesDir(),"reminder-music")))throw new IOException("Music save failed");
                        return;
                    }
                    if (!action.equals("export")) return;
                    if (pendingBackup != null) { showMessage("请先完成当前导出"); return; }
                    pendingBackup = message.getString("content");
                    Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/json").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,message.getString("filename"));
                    startActivityForResult(intent,SAVE_BACKUP);
                } catch (Exception error) { pendingBackup=null; showMessage("无法导出备份"); }
            });
        }
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if (request==PICK_FILE && fileCallback!=null) {
            fileCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result,data));
            fileCallback=null;
        }
        if (request==SAVE_BACKUP) {
            if (result==RESULT_OK && data!=null && data.getData()!=null && pendingBackup!=null) {
                try (OutputStream output=getContentResolver().openOutputStream(data.getData(),"wt")) {
                    if (output==null) throw new IOException("No output stream");
                    output.write(pendingBackup.getBytes(StandardCharsets.UTF_8));
                    showMessage("备份已保存");
                } catch (IOException error) { showMessage("保存备份失败，请重试"); }
            }
            pendingBackup=null;
        }
    }
    private void publishStatus() {
        try {
            boolean notifications=android.os.Build.VERSION.SDK_INT<33 || checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)==android.content.pm.PackageManager.PERMISSION_GRANTED;
            boolean exact=ReminderScheduler.exactAllowed(this);
            JSONObject status=new JSONObject().put("remindersEnabled",notifications && exact).put("playing",AlarmSoundService.playing).put("reminderStatus",!notifications?"请开启通知权限":!exact?"通知已开启，请允许准时提醒":"后台准时提醒已开启");
            webView.evaluateJavascript("window.rijianNativeStatus?.("+status+");",null);
        } catch(Exception ignored) {}
    }
    @Override protected void onStart(){super.onStart();visible=true;}
    @Override protected void onStop(){visible=false;super.onStop();}
    @Override protected void onResume(){super.onResume();if(webView!=null){ReminderScheduler.restore(this);publishStatus();}}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);publishStatus();}
    @Override public void onBackPressed() {
        webView.evaluateJavascript("(()=>{const d=[...document.querySelectorAll('dialog[open]')].pop();if(d){d.close();return true;}return false;})()",result->{ if (!"true".equals(result)) MainActivity.super.onBackPressed(); });
    }
    @Override protected void onDestroy() {
        if (fileCallback!=null) fileCallback.onReceiveValue(null);
        webView.destroy();
        super.onDestroy();
    }
}
