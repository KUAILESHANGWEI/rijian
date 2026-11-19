package com.shangweiqiu.rijian;

import android.app.*;
import android.content.*;
import android.media.*;
import android.os.*;
import java.io.File;

public final class AlarmSoundService extends Service {
    private MediaPlayer player;
    private AudioFocusRequest focus;
    public static volatile boolean playing=false;
    public static Notification notification(Context context,String title) {
        PendingIntent open=PendingIntent.getActivity(context,0,new Intent(context,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        Intent stop=new Intent(context,AlarmSoundService.class).setAction("stop");
        PendingIntent stopAction=PendingIntent.getService(context,1,stop,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(context,ReminderScheduler.CHANNEL).setSmallIcon(android.R.drawable.ic_lock_idle_alarm).setContentTitle("日缄 · 时间到").setContentText(title==null?"日子提醒":title).setContentIntent(open).setCategory(Notification.CATEGORY_ALARM).setOngoing(true).addAction(new Notification.Action.Builder(null,"停止播放",stopAction).build()).build();
    }
    @Override public int onStartCommand(Intent intent,int flags,int startId) {
        if(intent==null || "stop".equals(intent.getAction())) { stopSelf();return START_NOT_STICKY; }
        ReminderScheduler.initialize(this);
        startForeground(1,notification(this,intent.getStringExtra("title")));
        if(player!=null && player.isPlaying())return START_NOT_STICKY;
        try {
            AudioAttributes attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
            focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT).setAudioAttributes(attributes).setOnAudioFocusChangeListener(change->{if(change==AudioManager.AUDIOFOCUS_LOSS)stopSelf();}).build();
            getSystemService(AudioManager.class).requestAudioFocus(focus);
            player=new MediaPlayer();
            player.setAudioAttributes(attributes);
            File music=new File(getFilesDir(),"reminder-music");
            if(music.isFile())player.setDataSource(music.getAbsolutePath());
            else player.setDataSource(this,RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM));
            player.setLooping(true);
            player.setOnErrorListener((value,what,extra)->{stopSelf();return true;});
            player.prepare();player.start();playing=true;
        } catch(Exception error) { stopSelf(); }
        return START_NOT_STICKY;
    }
    @Override public void onDestroy() {
        playing=false;
        if(player!=null){player.release();player=null;}
        if(focus!=null)getSystemService(AudioManager.class).abandonAudioFocusRequest(focus);
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent){return null;}
}
