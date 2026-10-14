package vn.flygo.chat

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Kênh "flygo/open": mở một tệp của app bằng ứng dụng phù hợp (qua FileProvider),
/// dùng cho xem tệp đính kèm và cài bản cập nhật APK.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
