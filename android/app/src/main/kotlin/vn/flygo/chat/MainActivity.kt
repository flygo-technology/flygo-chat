package vn.flygo.chat

import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Kênh "flygo/open": mở một tệp của app bằng ứng dụng phù hợp (qua FileProvider),
/// dùng cho xem tệp đính kèm và cài bản cập nhật APK.
/// Kênh "flygo/urgent": bật/tắt hiện đè màn hình khoá + bật màn hình, chỉ trong lúc hiện tin khẩn cấp.
/// Kênh "flygo/clip": bộ nhớ tạm có ảnh / chữ không, chỉ xem mô tả (không đọc nội dung, Android không báo
/// "đã truy cập bộ nhớ tạm"); ảnh chỉ được đọc khi người dùng bấm "Dán ảnh" / "Dán" (Dart: lib/ui/clip.dart).
class MainActivity : FlutterActivity() {
    private fun overLock(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val f = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(f) else window.clearFlags(f)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flygo/urgent").setMethodCallHandler { call, result ->
            if (call.method != "overLock") return@setMethodCallHandler result.notImplemented()
            overLock(call.arguments == true)
            result.success(null)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flygo/clip").setMethodCallHandler { call, result ->
            if (call.method != "probe") return@setMethodCallHandler result.notImplemented()
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val d = try { cm?.primaryClipDescription } catch (e: Exception) { null }
            var image = false
            var text = false
            if (d != null) {
                for (i in 0 until d.mimeTypeCount) {
                    val m = d.getMimeType(i)
                    if (m.startsWith("image/")) image = true
                    if (m == "text/plain" || m == "text/html") text = true
                }
            }
            val stamp = if (d != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) d.timestamp else 0L
            result.success(mapOf("image" to image, "text" to text, "stamp" to stamp))
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flygo/open").setMethodCallHandler { call, result ->
            if (call.method != "open") return@setMethodCallHandler result.notImplemented()
            val path = call.argument<String>("path") ?: return@setMethodCallHandler result.success(false)
            val mime = call.argument<String>("mime") ?: "*/*"
            try {
                val uri = FileProvider.getUriForFile(this, "$packageName.provider", File(path))
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
                result.success(true)
            } catch (e: ActivityNotFoundException) {
                result.success(false)
            } catch (e: Exception) {
                result.success(false)
            }
        }
    }
}
