package com.shangweiqiu.rijian;
import android.content.*;
public final class ReminderReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context,Intent intent) {
        ReminderScheduler.initialize(context);
        if(Intent.ACTION_TIMEZONE_CHANGED.equals(intent.getAction()) || Intent.ACTION_TIME_CHANGED.equals(intent.getAction()) || Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction()) || Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction())) {
            ReminderScheduler.restore(context);
            return;
        }
        ReminderScheduler.advance(context,intent.getStringExtra("key"));
        if(!MainActivity.visible) ReminderScheduler.startSound(context,intent.getStringExtra("key"),intent.getStringExtra("title"));
    }
}
