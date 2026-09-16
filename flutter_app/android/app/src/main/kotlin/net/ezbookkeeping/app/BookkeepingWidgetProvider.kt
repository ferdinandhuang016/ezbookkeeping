package net.ezbookkeeping.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews

object HomeWidgetSupport {
    private const val PREFERENCES = "home_widgets"
    private val snapshotKeys = listOf(
        "year", "month", "incomeAmount", "incomeYearOverYear",
        "incomeTrend", "expenseAmount", "expenseYearOverYear", "expenseTrend",
        "totalAmount", "totalYearOverYear", "totalTrend"
    )

    fun updateSnapshot(context: Context, values: Map<*, *>) {
        val editor = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
        for (key in snapshotKeys) {
            val value = values[key]
            if (value == null) editor.remove(key) else editor.putString(key, value.toString())
        }
        editor.apply()
        updateAll(context)
    }

    fun clearSnapshot(context: Context) {
        val editor = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
        snapshotKeys.forEach(editor::remove)
        editor.apply()
        updateAll(context)
    }

    fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun quickAddIntent(context: Context, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_QUICK_ADD
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val quick = manager.getAppWidgetIds(ComponentName(context, QuickAddWidgetProvider::class.java))
        quick.forEach { QuickAddWidgetProvider.update(context, manager, it) }
        val summary = manager.getAppWidgetIds(ComponentName(context, SummaryWidgetProvider::class.java))
        summary.forEach { SummaryWidgetProvider.update(context, manager, it) }
    }
}

class QuickAddWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    companion object {
        fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_quick_add)
            val label = context.getString(R.string.widget_quick_add)
            views.setTextViewText(R.id.quick_add_label, label)
            views.setContentDescription(R.id.quick_add_widget, label)
            views.setOnClickPendingIntent(R.id.quick_add_widget, HomeWidgetSupport.quickAddIntent(context, id))
            manager.updateAppWidget(id, views)
        }
    }
}

class SummaryWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_SELECT_TAB) return
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        val tab = intent.getStringExtra(EXTRA_TAB) ?: return
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID || tab !in tabs) return
        HomeWidgetSupport.preferences(context).edit().putString("tab_$id", tab).apply()
        update(context, AppWidgetManager.getInstance(context), id)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val editor = HomeWidgetSupport.preferences(context).edit()
        ids.forEach { editor.remove("tab_$it") }
        editor.apply()
    }

    companion object {
        private const val ACTION_SELECT_TAB = "net.ezbookkeeping.app.action.SELECT_WIDGET_TAB"
        private const val EXTRA_TAB = "tab"
        private val tabs = listOf("income", "expense", "total")

        fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val preferences = HomeWidgetSupport.preferences(context)
            val selected = preferences.getString("tab_$id", "expense") ?: "expense"
            val views = RemoteViews(context.packageName, R.layout.widget_summary)
            views.setContentDescription(
                R.id.summary_widget,
                context.getString(R.string.widget_summary_description)
            )
            views.setTextViewText(R.id.summary_income, context.getString(R.string.widget_income))
            views.setTextViewText(R.id.summary_expense, context.getString(R.string.widget_expense))
            views.setTextViewText(R.id.summary_total, context.getString(R.string.widget_total))
            views.setTextViewText(R.id.summary_total_income_label, context.getString(R.string.widget_income))
            views.setTextViewText(R.id.summary_total_expense_label, context.getString(R.string.widget_expense))
            views.setTextViewText(R.id.summary_total_net_label, context.getString(R.string.widget_net_total))
            views.setTextViewText(R.id.summary_empty, context.getString(R.string.widget_open_to_update))
            val year = preferences.getString("year", null)
            val month = preferences.getString("month", null)
            views.setTextViewText(
                R.id.summary_period,
                if (year == null || month == null) context.getString(R.string.widget_this_month)
                else context.getString(R.string.widget_month_value, year.toInt(), month.toInt())
            )
            val amount = preferences.getString("${selected}Amount", null) ?: "—"
            val comparison = preferences.getString("${selected}YearOverYear", null) ?: "—"
            val trend = preferences.getString("${selected}Trend", "unavailable") ?: "unavailable"
            views.setTextViewText(R.id.summary_amount, amount)
            bindComparison(context, views, selected, comparison, trend)
            views.setViewVisibility(
                R.id.summary_empty,
                if (amount == "—") View.VISIBLE else View.GONE
            )
            val totalSelected = selected == "total"
            views.setViewVisibility(
                R.id.summary_single_values,
                if (totalSelected) View.GONE else View.VISIBLE
            )
            views.setViewVisibility(
                R.id.summary_total_values,
                if (totalSelected) View.VISIBLE else View.GONE
            )
            views.setTextViewText(
                R.id.summary_total_income_amount,
                preferences.getString("incomeAmount", null) ?: "—"
            )
            views.setTextViewText(
                R.id.summary_total_expense_amount,
                preferences.getString("expenseAmount", null) ?: "—"
            )
            views.setTextViewText(
                R.id.summary_total_net_amount,
                preferences.getString("totalAmount", null) ?: "—"
            )
            views.setOnClickPendingIntent(R.id.summary_widget, appIntent(context, id))
            bindTab(context, views, id, R.id.summary_income, "income", selected)
            bindTab(context, views, id, R.id.summary_expense, "expense", selected)
            bindTab(context, views, id, R.id.summary_total, "total", selected)
            manager.updateAppWidget(id, views)
        }

        private fun bindComparison(
            context: Context,
            views: RemoteViews,
            selected: String,
            comparison: String,
            trend: String
        ) {
            val arrow = when (trend) {
                "up" -> "▲"
                "down" -> "▼"
                else -> ""
            }
            val value = if (arrow.isEmpty()) comparison else comparison.trimStart('+', '-', '−')
            val text = if (arrow.isEmpty()) value else "$arrow $value"
            views.setTextViewText(
                R.id.summary_yoy,
                context.getString(R.string.widget_yoy_value, text)
            )
            val color = when {
                trend == "up" && selected == "expense" -> R.color.widget_trend_green
                trend == "down" && selected == "expense" -> R.color.widget_trend_red
                trend == "up" -> R.color.widget_trend_red
                trend == "down" -> R.color.widget_trend_green
                else -> R.color.widget_text_secondary
            }
            views.setTextColor(R.id.summary_yoy, context.getColor(color))
        }

        private fun bindTab(
            context: Context,
            views: RemoteViews,
            id: Int,
            viewId: Int,
            tab: String,
            selected: String
        ) {
            val intent = Intent(context, SummaryWidgetProvider::class.java).apply {
                action = ACTION_SELECT_TAB
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                putExtra(EXTRA_TAB, tab)
            }
            val requestCode = id * 10 + tabs.indexOf(tab)
            views.setOnClickPendingIntent(
                viewId,
                PendingIntent.getBroadcast(
                    context,
                    requestCode,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
            val active = tab == selected
            views.setInt(
                viewId,
                "setBackgroundResource",
                if (active) R.drawable.widget_tab_selected else android.R.color.transparent
            )
            views.setTextColor(
                viewId,
                context.getColor(if (active) R.color.widget_tab_active else R.color.widget_text_secondary)
            )
        }

        private fun appIntent(context: Context, id: Int): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = MainActivity.ACTION_OPEN_HOME
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            return PendingIntent.getActivity(
                context,
                id + 100000,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }
}
