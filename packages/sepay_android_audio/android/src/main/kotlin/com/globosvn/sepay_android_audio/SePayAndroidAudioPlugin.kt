package com.globosvn.sepay_android_audio

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class SePayAndroidAudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.globosvn/sepay_android_audio")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "announce") {
            result.notImplemented()
            return
        }

        val tokens = call.argument<List<String>>("tokens")
            ?.filter { it.matches(Regex("[a-z0-9_]{1,32}")) }
            ?.take(32)
            .orEmpty()
        if (tokens.isEmpty()) {
            result.success(false)
            return
        }

        val intent = Intent(context, SePayAudioService::class.java).apply {
            putStringArrayListExtra(SePayAudioService.EXTRA_TOKENS, ArrayList(tokens))
        }
        try {
            ContextCompat.startForegroundService(context, intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
