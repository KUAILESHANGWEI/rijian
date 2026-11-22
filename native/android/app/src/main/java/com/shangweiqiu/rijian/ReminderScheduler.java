package com.shangweiqiu.rijian;

import android.app.*;
import android.content.*;
import android.net.Uri;
import android.os.Build;
import org.json.*;
import java.util.*;

public final class ReminderScheduler {
    public static final String CHANNEL = "rijian-alarm-v1";
    private ReminderScheduler() {}
    private static android.content.SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("native-reminders",Context.MODE_PRIVATE);
    }
    public static void initialize(Context context) {
        NotificationChannel channel = new NotificationChannel(CHANNEL,"日子与倒计时提醒",NotificationManager.IMPORTANCE_HIGH);
        channel.setDescription("到时提醒并播放音乐，点击停止结束响铃");
        channel.setSound(null,null);
        channel.enableVibration(true);
        context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }
    public static boolean exactAllowed(Context context) {
        return Build.VERSION.SDK_INT < 31 || context.getSystemService(AlarmManager.class).canScheduleExactAlarms();
    }
    private static PendingIntent alarmIntent(Context context,JSONObject item) {
        Intent intent = new Intent(context,ReminderReceiver.class).setAction("com.shangweiqiu.rijian.ALARM").setData(Uri.parse("rijian://reminder/"+Uri.encode(item.optString("key"))));
        intent.putExtra("key",item.optString("key"));
        intent.putExtra("title",item.optString("title","日子提醒"));
        return PendingIntent.getBroadcast(context,0,intent,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
    }
    public static synchronized void sync(Context context,JSONArray incoming) {
        AlarmManager manager = context.getSystemService(AlarmManager.class);
        try {
            JSONArray previous = new JSONArray(preferences(context).getString("requests","[]"));
            for(int index=0;index<previous.length();index++) manager.cancel(alarmIntent(context,previous.getJSONObject(index)));
            JSONArray valid = new JSONArray();
            long now = System.currentTimeMillis();
            for(int index=0;index<incoming.length() && valid.length()<61;index++) {
                JSONObject item = incoming.getJSONObject(index);
                long time=item.optLong("time",0);
                if(item.optString("key").isEmpty() || time<=now)continue;
                valid.put(item);
                PendingIntent pending=alarmIntent(context,item);
                if(exactAllowed(context)) manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,time,pending);
                else manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,time,pending);
            }
            preferences(context).edit().putString("requests",valid.toString()).commit();
        } catch(Exception error) { throw new IllegalStateException("系统提醒保存失败",error); }
    }
    public static void restore(Context context) {
        try {
            JSONArray items=new JSONArray(preferences(context).getString("requests","[]"));
            for(int n=0;n<items.length();n++){JSONObject item=items.getJSONObject(n);if(item.optString("key").startsWith("alarm-"))advance(context,item.optString("key"));}
            sync(context,new JSONArray(preferences(context).getString("requests","[]")));
        }
        catch(Exception ignored) {}
    }
    public static void advance(Context context,String key) {
        if(key==null||!key.startsWith("alarm-"))return;
        try {
            JSONArray items=new JSONArray(preferences(context).getString("requests","[]"));
            for(int n=0;n<items.length();n++){
                JSONObject item=items.getJSONObject(n);if(!item.optString("key").startsWith("alarm-"))continue;
                JSONArray days=item.optJSONArray("weekdays");if(days==null||days.length()==0)continue;
                long now=System.currentTimeMillis();
                for(int offset=0;offset<=7;offset++){
                    java.util.Calendar date=java.util.Calendar.getInstance();date.add(java.util.Calendar.DATE,offset);
                    date.set(java.util.Calendar.HOUR_OF_DAY,item.getInt("hour"));date.set(java.util.Calendar.MINUTE,item.getInt("minute"));date.set(java.util.Calendar.SECOND,0);date.set(java.util.Calendar.MILLISECOND,0);
                    boolean matches=false;for(int d=0;d<days.length();d++)if(days.getInt(d)==date.get(java.util.Calendar.DAY_OF_WEEK)-1)matches=true;
                    if(matches&&date.getTimeInMillis()>now){item.put("time",date.getTimeInMillis());break;}
                }
            }
            sync(context,items);
        }catch(Exception ignored){}
    }
    public static synchronized boolean claim(Context context,String key) {
        if(key!=null&&key.startsWith("alarm-")){
            String clock="";try{JSONArray items=new JSONArray(preferences(context).getString("requests","[]"));for(int n=0;n<items.length();n++){JSONObject item=items.getJSONObject(n);if(key.equals(item.optString("key")))clock="-"+item.optInt("hour")+"-"+item.optInt("minute");}}catch(Exception ignored){}
            java.util.Calendar day=java.util.Calendar.getInstance();key=key+"-"+day.get(java.util.Calendar.YEAR)+"-"+day.get(java.util.Calendar.DAY_OF_YEAR)+clock;
        }
        Set<String> keys=new HashSet<>(preferences(context).getStringSet("fired",Collections.emptySet()));
        if(keys.contains(key))return false;
        if(keys.size()>1000)keys.clear();
        keys.add(key);
        preferences(context).edit().putStringSet("fired",keys).commit();
        return true;
    }
    public static void startSound(Context context,String key,String title) {
        if(!claim(context,key))return;
        Intent sound=new Intent(context,AlarmSoundService.class).putExtra("title",title).putExtra("key",key);
        try { context.startForegroundService(sound); }
        catch(Exception error) {
            NotificationManager manager=context.getSystemService(NotificationManager.class);
            manager.notify(key.hashCode(),AlarmSoundService.notification(context,title));
        }
    }
}
