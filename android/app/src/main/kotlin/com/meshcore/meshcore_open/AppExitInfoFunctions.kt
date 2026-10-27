package com.meshcore.meshcore_open

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Reads the system's record of why this app's processes died, so an ANR that
 * killed the process can be reported on the next launch (#906).
 *
 * `ActivityManager.getHistoricalProcessExitReasons` is API 30; `minSdk` here is
 * 24, so everything below reports itself unsupported rather than failing. The
 * query and the trace reads run on a background executor: #334 is the leading
 * hypothesis for these ANRs, so a collector that blocked the main thread would
 * be adding to the problem it exists to measure.
 */
class AppExitInfoFunctions(
    private val activity: FlutterActivity,
) {
    private companion object {
        /** Bound on the query. The system keeps a ring buffer of unspecified size. */
        const val maxRecords = 15

        /** Per-trace read cap, so one pathological trace can't be unbounded. */
        const val maxTraceBytes = 256 * 1024
    }

    private val channelName = "meshcore_open/app_exit_info"

    private val activityManager by lazy {
        activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile private var disposed = false

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getExitRecords" -> handleGetExitRecords(result)
                    "forceMainThreadBlock" -> handleForceMainThreadBlock(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    fun dispose() {
        disposed = true
        // shutdown(), NOT shutdownNow(): an in-flight read is holding a
        // MethodChannel.Result, and interrupting it would leave that Result
        // neither succeeded nor errored, so the Dart future would never
        // complete. Letting the task finish is cheap; a hung future is not.
        ioExecutor.shutdown()
    }

    private fun handleGetExitRecords(result: MethodChannel.Result) {
        if (disposed) {
            result.error("exit_info_disposed", "activity is being destroyed", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(
                mapOf(
                    "supported" to false,
                    "unsupportedReason" to "api_below_30",
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "records" to emptyList<Map<String, Any?>>(),
                ),
            )
            return
        }

        try {
            ioExecutor.execute {
                try {
                    val records = collectExitRecords()
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "supported" to true,
                                "sdkInt" to Build.VERSION.SDK_INT,
                                "records" to records,
                            ),
                        )
                    }
                } catch (error: Exception) {
                    // Surfaced, never swallowed: Dart logs this and leaves the
                    // watermark untouched so the next launch retries.
                    mainHandler.post {
                        result.error(
                            "exit_info_query_failed",
                            error.message ?: error.javaClass.simpleName,
                            error.stackTraceToString().take(2000),
                        )
                    }
                }
            }
        } catch (error: RejectedExecutionException) {
            // The executor shut down between the disposed check and here. Reply
            // rather than returning silently, so the Dart future completes.
            result.error("exit_info_rejected", error.message ?: "executor shut down", null)
        }
    }

    /**
     * API 30+ only, isolated in its own method so the verifier never has to
     * resolve [ApplicationExitInfo] on a device that cannot run this path.
     */
    private fun collectExitRecords(): List<Map<String, Any?>> {
        // null package name means this app's own records, which needs no permission.
        val infos = activityManager.getHistoricalProcessExitReasons(null, 0, maxRecords)
        return infos.map { info -> describe(info) }
    }

    private fun describe(info: ApplicationExitInfo): Map<String, Any?> {
        val record = mutableMapOf<String, Any?>(
            "reason" to info.reason,
            "reasonName" to reasonName(info.reason),
            "description" to info.description,
            "timestampMs" to info.timestamp,
            "pid" to info.pid,
            "processName" to info.processName,
            "importance" to info.importance,
            // Documented as kB, and 0 when the system never sampled the process.
            "pssKb" to info.pss,
            "rssKb" to info.rss,
            "status" to info.status,
        )

        readTrace(info, record)
        return record
    }

    /**
     * A text ANR trace is printable ASCII; a native tombstone protobuf is not.
     *
     * Content, not reason code, decides whether the bytes are usable. Gating on
     * [ApplicationExitInfo.REASON_CRASH_NATIVE] instead would lose a real text
     * trace, because AOSP says a trace from an earlier ANR stays attached to the
     * record even when the process later died for a different reason.
     */
    private fun looksLikeText(bytes: ByteArray): Boolean {
        val sample = minOf(bytes.size, 256)
        if (sample == 0) return false
        var printable = 0
        for (i in 0 until sample) {
            val b = bytes[i].toInt() and 0xFF
            if (b == 0x09 || b == 0x0A || b == 0x0D || (b in 0x20..0x7E)) printable++
        }
        return printable * 10 >= sample * 9
    }

    /**
     * A trace is NOT guaranteed, even for [ApplicationExitInfo.REASON_ANR]: the
     * system keeps traces in a circular buffer shared across all applications,
     * so another app's crash can evict ours. A trace can also ride on a record
     * whose reason is something else, when the process survived an ANR and died
     * later for another reason. So this attempts the read on every record and
     * treats absence as an ordinary outcome, not an error.
     *
     * `getTraceInputStream()` is declared `throws IOException`, so the call
     * itself is inside the try, not only the reads on the stream it returns.
     */
    private fun readTrace(info: ApplicationExitInfo, record: MutableMap<String, Any?>) {
        try {
            val stream = info.traceInputStream
            if (stream == null) {
                record["traceUnavailable"] = "evicted_or_absent"
                return
            }
            stream.use { open ->
                // Read loop rather than readNBytes: that one is API 33, and this
                // path has to work from API 30 up.
                val sink = ByteArrayOutputStream()
                val chunk = ByteArray(8192)
                while (sink.size() < maxTraceBytes) {
                    val read = open.read(chunk, 0, minOf(chunk.size, maxTraceBytes - sink.size()))
                    if (read <= 0) break
                    sink.write(chunk, 0, read)
                }
                if (sink.size() == 0) {
                    record["traceUnavailable"] = "empty_stream"
                    return
                }
                val bytes = sink.toByteArray()
                if (!looksLikeText(bytes)) {
                    // Almost certainly a native tombstone protobuf (API 31+).
                    // Recorded rather than written, because concatenating binary
                    // into a text log would corrupt it (#906).
                    record["traceUnavailable"] = "binary_tombstone_not_text"
                    return
                }
                record["traceBytes"] = bytes
                if (bytes.size >= maxTraceBytes) {
                    record["traceTruncated"] = true
                }
            }
        } catch (error: IOException) {
            record["traceUnavailable"] = "io_error: ${error.message ?: "IOException"}"
        }
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        else -> "UNKNOWN"
    }

    /**
     * Test-only: hangs the main thread so the system raises a real ANR, which is
     * the only way to produce an [ApplicationExitInfo.REASON_ANR] record. No adb
     * command induces one. Unreachable in a shipped build, because the only
     * caller is compiled out unless `OFFBAND_ANR_TEST` is defined (#911).
     *
     * Replies before blocking so the Dart call completes; the block then runs on
     * the next turn of the main looper.
     */
    private fun handleForceMainThreadBlock(call: MethodCall, result: MethodChannel.Result) {
        val millis = (call.argument<Int>("millis") ?: 20000).coerceIn(1000, 120000)
        result.success(millis)
        mainHandler.post {
            // Sleeps to a deadline and swallows interrupts rather than a single
            // Thread.sleep. An interrupt cutting the block short would mean no
            // ANR, no record, and a wasted trip to the hardware. Looping on
            // short sleeps keeps the duration guaranteed without the CPU burn
            // (and thermal throttling) of a busy-wait.
            val deadline = System.nanoTime() + millis * 1_000_000L
            while (true) {
                val remainingMs = (deadline - System.nanoTime()) / 1_000_000L
                if (remainingMs <= 0) break
                try {
                    Thread.sleep(minOf(remainingMs, 250L))
                } catch (_: InterruptedException) {
                    // Deliberately ignored; the deadline is what ends this.
                }
            }
        }
    }
}
