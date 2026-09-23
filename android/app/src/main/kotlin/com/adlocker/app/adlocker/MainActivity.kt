package com.adlocker.app.adlocker

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "com.adlocker.app/vpn"
    private val EVENT_CHANNEL = "com.adlocker.app/dns_stream"
    private val VPN_REQUEST_CODE = 2026
    private var pendingResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val vpnIntent = VpnService.prepare(this)
                    if (vpnIntent != null) {
                        pendingResult = result
                        startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                    } else {
                        startServiceDirectly()
                        result.success(true)
                    }
                }
                "stopVpn" -> {
                    val stopIntent = Intent(this, AdLockerVpnService::class.java).apply {
                        action = "STOP"
                    }
                    startService(stopIntent)
                    result.success(true)
                }
                "isVpnActive" -> {
                    result.success(AdLockerVpnService.isRunning)
                }
                "getRulesCount" -> {
                    result.success(AdLockerVpnService.activeRulesCount)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    AdLockerVpnService.queryListener = { data ->
                        eventSink?.success(data)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    AdLockerVpnService.queryListener = null
                }
            }
        )
    }

    private fun startServiceDirectly() {
        val serviceIntent = Intent(this, AdLockerVpnService::class.java)
        startService(serviceIntent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                startServiceDirectly()
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
        }
    }
}
