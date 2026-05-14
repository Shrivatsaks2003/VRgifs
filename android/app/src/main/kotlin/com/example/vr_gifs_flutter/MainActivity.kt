package com.example.vr_gifs_flutter

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.provider.OpenableColumns
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.InputConnection
import android.widget.EditText
import androidx.core.view.ContentInfoCompat
import androidx.core.view.ViewCompat
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

class MainActivity : FlutterActivity() {
    private val methodChannelName = "vrgifs/share_intent/methods"
    private val eventChannelName = "vrgifs/share_intent/events"
    private val keyboardInputViewType = "vrgifs/gif_input_view"

    private var pendingInitialSharedGif: Map<String, String>? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler(::handleMethodCall)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                },
            )

        flutterEngine
            .platformViewsController
            .registry
            .registerViewFactory(
                keyboardInputViewType,
                GifInputViewFactory(this) { gifPayload ->
                    eventSink?.success(gifPayload)
                },
            )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val sharedGif = extractSharedGif(intent)
        if (sharedGif != null) {
            eventSink?.success(sharedGif)
        }
    }

    override fun onResume() {
        super.onResume()
        if (pendingInitialSharedGif == null) {
            pendingInitialSharedGif = extractSharedGif(intent)
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInitialSharedGif" -> {
                if (pendingInitialSharedGif == null) {
                    pendingInitialSharedGif = extractSharedGif(intent)
                }
                result.success(pendingInitialSharedGif)
                pendingInitialSharedGif = null
            }

            else -> result.notImplemented()
        }
    }

    private fun extractSharedGif(intent: Intent?): Map<String, String>? {
        if (intent?.action != Intent.ACTION_SEND) {
            return null
        }

        val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: return null
        return copyGifUriToCache(uri, source = "share_sheet")
    }

    private fun copyGifUriToCache(uri: Uri, source: String): Map<String, String>? {
        val mimeType = contentResolver.getType(uri).orEmpty()
        val originalName = queryDisplayName(uri) ?: "shared_${System.currentTimeMillis()}.gif"
        val normalizedName =
            if (originalName.lowercase().endsWith(".gif")) {
                originalName
            } else {
                "$originalName.gif"
            }

        if (mimeType.isNotBlank() && mimeType != "image/gif" && !normalizedName.lowercase().endsWith(".gif")) {
            return null
        }

        val targetFile = File(cacheDir, "shared_${System.currentTimeMillis()}_$normalizedName")
        contentResolver.openInputStream(uri)?.use { input ->
            targetFile.outputStream().use { output ->
                input.copyTo(output)
            }
        } ?: return null

        return mapOf(
            "path" to targetFile.path,
            "name" to normalizedName,
            "mimeType" to if (mimeType.isBlank()) "image/gif" else mimeType,
            "source" to source,
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        val cursor: Cursor = contentResolver.query(uri, null, null, null, null) ?: return null
        cursor.use {
            val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex == -1 || !it.moveToFirst()) {
                return null
            }
            return it.getString(nameIndex)
        }
    }

    private class GifInputViewFactory(
        private val activity: MainActivity,
        private val onGifReceived: (Map<String, String>) -> Unit,
    ) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            return GifInputPlatformView(activity, context, onGifReceived)
        }
    }

    private class GifInputPlatformView(
        private val activity: MainActivity,
        context: Context,
        private val onGifReceived: (Map<String, String>) -> Unit,
    ) : PlatformView {
        private val acceptedMimeTypes = arrayOf("image/gif", "image/*")
        private val editText =
            GifReceivingEditText(context, acceptedMimeTypes).apply {
                layoutParams =
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                gravity = Gravity.CENTER_VERTICAL
                hint = "Tap here, then send a GIF from keyboard"
                setTextColor(Color.WHITE)
                setHintTextColor(Color.parseColor("#88FFFFFF"))
                setPadding(36, 24, 36, 24)
                textSize = 15f
                typeface = Typeface.DEFAULT_BOLD
                inputType = InputType.TYPE_CLASS_TEXT
                background =
                    GradientDrawable().apply {
                        cornerRadius = 28f
                        setColor(Color.parseColor("#132433"))
                        setStroke(2, Color.parseColor("#5544E0D8"))
                    }

                ViewCompat.setOnReceiveContentListener(
                    this,
                    acceptedMimeTypes,
                ) { _, payload ->
                    handleIncomingContent(payload)
                }

                setOnClickListener {
                    requestFocus()
                    val imm =
                        context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
                }
            }

        override fun getView(): View = editText

        override fun dispose() = Unit

        private fun handleIncomingContent(payload: ContentInfoCompat): ContentInfoCompat? {
            val split = payload.partition { item -> item.uri != null }
            val uriContent = split.first
            val remaining = split.second

            uriContent?.clip?.let { clipData ->
                for (index in 0 until clipData.itemCount) {
                    val uri = clipData.getItemAt(index).uri ?: continue
                    val importedGif = activity.copyGifUriToCache(uri, source = "keyboard_input")
                    if (importedGif != null) {
                        onGifReceived(importedGif)
                        editText.setText("GIF received")
                        editText.clearFocus()
                    }
                }
            }

            return remaining
        }
    }

    private class GifReceivingEditText(
        context: Context,
        private val acceptedMimeTypes: Array<String>,
    ) : EditText(context) {
        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
            var inputConnection = super.onCreateInputConnection(outAttrs)
            EditorInfoCompat.setContentMimeTypes(outAttrs, acceptedMimeTypes)
            val mimeTypes = ViewCompat.getOnReceiveContentMimeTypes(this)
            if (mimeTypes != null && inputConnection != null) {
                EditorInfoCompat.setContentMimeTypes(outAttrs, mimeTypes)
                inputConnection =
                    InputConnectionCompat.createWrapper(this, inputConnection, outAttrs)
            }
            return inputConnection
        }
    }
}
