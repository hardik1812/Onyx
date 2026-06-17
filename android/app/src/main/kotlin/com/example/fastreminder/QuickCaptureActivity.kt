package com.example.fastreminder

import android.app.Activity
import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import android.os.Bundle
import android.view.WindowManager
import android.widget.*
import android.text.Editable
import android.text.TextWatcher
import android.app.TimePickerDialog
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.view.View
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar

class QuickCaptureActivity : Activity() {
    private var currentFolder = "General"
    private var selectedAttachmentPath: String? = null
    private val PICK_IMAGE = 1

    private val folderColors = mapOf(
        "Work" to "#FF80AB",      // Pink
        "Shopping" to "#FFD180",  // Orange
        "Health" to "#B9F6CA",    // Green
        "College" to "#82B1FF",   // Blue
        "Social" to "#EA80FC",    // Purple
        "Home" to "#CFD8DC",      // Blue Gray
        "Finance" to "#CCFF90",   // Lime
        "UI/UX" to "#84FFFF",     // Cyan
        "Backend" to "#FF9E80",   // Deep Orange
        "Database" to "#FFFF8D",  // Yellow
        "Testing" to "#F4FF81",   // Lime Green
        "DevOps" to "#B2FF59",    // Light Green
        "Icebox" to "#A7FFEB"     // Teal
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_quick_capture)

        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE)

        val editText = findViewById<EditText>(R.id.edit_text)
        val saveButton = findViewById<ImageView>(R.id.save_button)
        val folderTag = findViewById<TextView>(R.id.folder_tag)
        val btnGallery = findViewById<ImageView>(R.id.btn_gallery)
        val btnTimer = findViewById<ImageView>(R.id.btn_timer)
        val functionsPalette = findViewById<LinearLayout>(R.id.functions_palette)
        val colorContainer = findViewById<LinearLayout>(R.id.color_scroll_container)

        setupColorPalette(colorContainer, editText)

        editText.requestFocus()

        editText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val text = s.toString()
                
                // Show palette if /functions is typed
                if (text.trim() == "/functions") {
                    functionsPalette.visibility = View.VISIBLE
                } else {
                    functionsPalette.visibility = View.GONE
                }

                currentFolder = classifyIntent(text)
                folderTag.text = currentFolder
                
                // Update tag color
                val colorStr = folderColors[currentFolder] ?: "#A8C7FA"
                folderTag.setTextColor(Color.parseColor(colorStr))
                val bg = folderTag.background as GradientDrawable
                bg.setColor(Color.parseColor(colorStr).adjustAlpha(0.2f))
            }
            override fun afterTextChanged(s: Editable?) {}
        })

        btnGallery.setOnClickListener {
            val intent = Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
            startActivityForResult(intent, PICK_IMAGE)
        }

        btnTimer.setOnClickListener {
            val c = Calendar.getInstance()
            TimePickerDialog(this, { _, hour, minute ->
                val now = Calendar.getInstance()
                val picked = Calendar.getInstance()
                picked.set(Calendar.HOUR_OF_DAY, hour)
                picked.set(Calendar.MINUTE, minute)
                picked.set(Calendar.SECOND, 0)
                picked.set(Calendar.MILLISECOND, 0)

                var diff = (picked.timeInMillis - now.timeInMillis) / 60000
                if (diff < 0) diff += 1440 // Next day

                val currentText = editText.text.toString()
                val spacer = if (currentText.isNotEmpty() && !currentText.endsWith(" ")) " " else ""
                editText.append("${spacer}in ${diff}m")
            }, c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE), false).show()
        }

        saveButton.setOnClickListener {
            val text = editText.text.toString().trim()
            if (text.isNotEmpty()) {
                saveReminder(text)
                finish()
            }
        }
    }

    private fun setupColorPalette(container: LinearLayout, editText: EditText) {
        for ((name, color) in folderColors) {
            val view = View(this)
            val params = LinearLayout.LayoutParams(120, 120)
            params.setMargins(16, 8, 16, 8)
            view.layoutParams = params
            
            val shape = GradientDrawable()
            shape.shape = GradientDrawable.OVAL
            shape.setColor(Color.parseColor(color))
            view.background = shape
            
            view.setOnClickListener {
                val currentText = editText.text.toString().replace("/functions", "").trim()
                editText.setText("$currentText @$name ")
                editText.setSelection(editText.text.length)
            }
            
            container.addView(view)
        }
    }

    private fun Int.adjustAlpha(factor: Float): Int {
        val alpha = Math.round(Color.alpha(this) * factor)
        val red = Color.red(this)
        val green = Color.green(this)
        val blue = Color.blue(this)
        return Color.argb(alpha, red, green, blue)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_IMAGE && resultCode == RESULT_OK && data != null) {
            val selectedImage: Uri? = data.data
            selectedAttachmentPath = getPathFromUri(selectedImage)
            if (selectedAttachmentPath != null) {
                findViewById<ImageView>(R.id.btn_gallery).setColorFilter(0xFFA8C7FA.toInt())
            }
        }
    }

    private fun getPathFromUri(uri: Uri?): String? {
        if (uri == null) return null
        val projection = arrayOf(MediaStore.Images.Media.DATA)
        val cursor = contentResolver.query(uri, projection, null, null, null)
        if (cursor != null) {
            val columnIndex = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)
            cursor.moveToFirst()
            val path = cursor.getString(columnIndex)
            cursor.close()
            return path
        }
        return uri.path
    }

    fun dismissAction(view: android.view.View) {
        finish()
    }

    private fun classifyIntent(text: String): String {
        // Higher priority for explicit @mention
        val words = text.split(Regex("\\s+"))
        for (word in words) {
            if (word.startsWith("@") && word.length > 1) {
                val tag = word.substring(1).filter { it.isLetterOrDigit() }.lowercase()
                for (cat in folderColors.keys) {
                    if (cat.lowercase() == tag) return cat
                }
                // If not in our list but it's a tag, return capitalized tag
                if (tag.isNotEmpty()) return tag.replaceFirstChar { it.uppercase() }
            }
        }

        val rules = mapOf(
            "Work" to listOf("call", "email", "meeting", "report", "project", "office", "task"),
            "Shopping" to listOf("buy", "eggs", "milk", "shop", "grocery", "amazon", "list"),
            "Health" to listOf("doctor", "gym", "meds", "workout", "appointment", "pill"),
            "College" to listOf("assignment", "lecture", "exam", "study", "homework", "class"),
            "Social" to listOf("friend", "party", "dinner", "birthday", "meetup", "date"),
            "Home" to listOf("clean", "laundry", "dishes", "repair", "rent", "bills"),
            "Finance" to listOf("bank", "money", "stock", "tax", "budget", "savings"),
            "UI/UX" to listOf("button", "layout", "design", "color", "font", "icon", "ui"),
            "Backend" to listOf("api", "server", "route", "auth", "logic", "rust", "node"),
            "Database" to listOf("db", "sql", "query", "table", "schema", "sqlite", "mongo"),
            "Testing" to listOf("test", "unit", "debug", "bug", "fix", "coverage"),
            "DevOps" to listOf("deploy", "docker", "k8s", "cloud", "aws", "pipeline"),
            "Icebox" to listOf("later", "maybe", "someday", "future", "v2", "backlog")
        )

        val scoreboard = mutableMapOf<String, Int>()
        val lowercaseText = text.lowercase()
        for ((category, keywords) in rules) {
            for (kw in keywords) {
                if (lowercaseText.contains(kw)) {
                    scoreboard[category] = scoreboard.getOrDefault(category, 0) + 1
                }
            }
        }

        return scoreboard.maxByOrNull { it.value }?.key ?: "General"
    }

    private fun saveReminder(contextText: String) {
        try {
            var finalContext = contextText
            
            if (contextText.trim() == "/l" || contextText.startsWith("/l ")) {
                val title = if (contextText.trim() == "/l") "List" else contextText.substring(3).trim()
                val json = JSONObject()
                json.put("type", "list")
                json.put("title", title)
                json.put("items", JSONArray())
                finalContext = json.toString()
            }

            val dbFile = File(filesDir.parentFile, "app_flutter/reminders.db")
            val db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
            
            val values = ContentValues().apply {
                put("context", finalContext)
                put("folder", currentFolder)
                put("importance", 5)
                put("date_of_creation", System.currentTimeMillis() / 1000)
                put("attachment_path", selectedAttachmentPath)
                put("is_pinned", 0)
            }

            db.insert("reminders", null, values)
            db.close()
            
            Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, "Error: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }
}