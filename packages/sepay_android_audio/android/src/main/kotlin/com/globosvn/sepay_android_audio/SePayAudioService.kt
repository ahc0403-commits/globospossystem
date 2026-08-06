package com.globosvn.sepay_android_audio

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.ArrayDeque

class SePayAudioService : Service() {
    companion object {
        const val EXTRA_TOKENS = "tokens"
        private const val CHANNEL_ID = "sepay_audio_playback"
        private const val NOTIFICATION_ID = 93456
        private const val TAG = "SePayAudioService"
        private const val ASSET_PREFIX = "flutter_assets/assets/audio/bank_transfer_vi/"
    }

    private val phraseQueue = ArrayDeque<List<String>>()
    private var currentTokens: List<String> = emptyList()
    private var tokenIndex = 0
    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var audioManager: AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false
    private var playing = false

    override fun onCreate() {
        super.onCreate()
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                foregroundNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, foregroundNotification())
        }
        val tokens = intent?.getStringArrayListExtra(EXTRA_TOKENS)
            ?.filter { it.matches(Regex("[a-z0-9_]{1,32}")) }
            ?.take(32)
            .orEmpty()
        if (tokens.isNotEmpty()) {
            phraseQueue.addLast(tokens)
        }
        if (!playing) startNextPhrase()
        return START_NOT_STICKY
    }

    private fun startNextPhrase() {
        val next = phraseQueue.pollFirst()
        if (next == null) {
            finishService()
            return
        }
        playing = true
        currentTokens = next
        tokenIndex = 0
        acquireWakeLock()
        requestAudioFocus()
        playNextToken()
    }

    private fun requestAudioFocus(): Boolean {
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener { }
                .build()
            focusRequest = request
            hasAudioFocus = audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            hasAudioFocus = audioManager.requestAudioFocus(
                null,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        Log.i(TAG, "SEPAY_AUDIO_FOCUS granted=$hasAudioFocus")
        return hasAudioFocus
    }

    private fun playNextToken() {
        if (tokenIndex >= currentTokens.size) {
            Log.i(TAG, "SEPAY_AUDIO_COMPLETE tokens=${currentTokens.size}")
            releasePhraseResources()
            playing = false
            startNextPhrase()
            return
        }

        val token = currentTokens[tokenIndex++]
        try {
            player?.release()
            val descriptor = assets.openFd("$ASSET_PREFIX$token.mp3")
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.length)
                descriptor.close()
                setOnCompletionListener { playNextToken() }
                setOnErrorListener { _, what, extra ->
                    Log.e(TAG, "SEPAY_AUDIO_ERROR token=$token what=$what extra=$extra")
                    playNextToken()
                    true
                }
                prepare()
                start()
            }
            Log.i(TAG, "SEPAY_AUDIO_TOKEN $token")
        } catch (error: Exception) {
            Log.e(TAG, "SEPAY_AUDIO_ERROR token=$token", error)
            playNextToken()
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:sepay-audio",
        ).apply { acquire(60_000L) }
    }

    private fun releasePhraseResources() {
        player?.release()
        player = null
        if (hasAudioFocus) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let(audioManager::abandonAudioFocusRequest)
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(null)
            }
        }
        hasAudioFocus = false
        focusRequest = null
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun finishService() {
        releasePhraseResources()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Bank transfer voice playback",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setSound(null, null) },
        )
    }

    private fun foregroundNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(applicationInfo.icon)
        .setContentTitle("Đang đọc khoản chuyển")
        .setContentText("Đang phát thông báo số tiền đã nhận")
        .setOngoing(true)
        .setSilent(true)
        .build()

    override fun onDestroy() {
        phraseQueue.clear()
        releasePhraseResources()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
