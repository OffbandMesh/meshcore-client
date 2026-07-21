package com.meshcore.meshcore_open

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }

    private val appLifecycleChannelName = "meshcore_open/app_lifecycle"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appLifecycleChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Send the task to the background WITHOUT finishing the
                // activity. SystemNavigator.pop() calls finish(), which tears
                // down the Flutter engine and drops the radio connection, so
                // reopening the app lands on a disconnected radio.
                "moveTaskToBack" -> {
                    result.success(moveTaskToBack(true))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        usbFunctions.dispose()
        super.onDestroy()
    }
}
