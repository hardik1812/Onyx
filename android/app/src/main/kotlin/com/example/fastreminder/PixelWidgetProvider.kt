package com.example.fastreminder

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class PixelWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.pixel_widget)
            
            // Intent to launch the Quick Capture overlay
            val intent = Intent(context, QuickCaptureActivity::class.java)
            val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            
            views.setOnClickPendingIntent(R.id.pixel_widget_root, pendingIntent)
            views.setOnClickPendingIntent(R.id.widget_text, pendingIntent)
            views.setOnClickPendingIntent(R.id.widget_camera, pendingIntent)
            views.setOnClickPendingIntent(R.id.widget_add_btn, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}