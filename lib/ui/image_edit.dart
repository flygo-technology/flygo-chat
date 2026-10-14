import '../i18n/i18n.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// Mở trình sửa ảnh (vẽ có chọn màu, cắt, xoay). Trả về đường dẫn ảnh đã sửa,
/// hoặc null nếu người dùng hủy.
Future<String?> editImage(BuildContext context, String path) async {
  Uint8List? result;
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (ctx) => ProImageEditor.file(
      File(path),
      configs: ProImageEditorConfigs(
        designMode: ImageEditorDesignMode.cupertino,
        mainEditor: MainEditorConfigs(tools: [SubEditorMode.paint, SubEditorMode.cropRotate]),
        // Mặc định trình sửa thu ảnh về tối đa 2000px; giữ gần nguyên độ phân giải ảnh gốc.
        imageGeneration: const ImageGenerationConfigs(maxOutputSize: Size(8000, 8000), jpegQuality: 92),
        i18n: I18n(
          cancel: tr('Hủy'),
          undo: tr('Hoàn tác'),
          redo: tr('Làm lại'),
          done: tr('Xong'),
          remove: tr('Xóa'),
          doneLoadingMsg: tr('Đang lưu ảnh...'),
          paintEditor: I18nPaintEditor(
            bottomNavigationBarText: tr('Vẽ'),
            freestyle: tr('Vẽ tự do'),
            arrow: tr('Mũi tên'),
            line: tr('Đường thẳng'),
            rectangle: tr('Hình chữ nhật'),
            circle: tr('Hình tròn'),
            dashLine: tr('Nét đứt'),
            lineWidth: tr('Độ dày nét'),
            eraser: tr('Tẩy'),
            toggleFill: tr('Tô đặc'),
            changeOpacity: tr('Độ mờ'),
            undo: tr('Hoàn tác'),
            redo: tr('Làm lại'),
            done: tr('Xong'),
            back: tr('Quay lại'),
            smallScreenMoreTooltip: tr('Thêm'),
            moveAndZoom: tr('Phóng to'),
          ),
          cropRotateEditor: I18nCropRotateEditor(
            bottomNavigationBarText: tr('Cắt / Xoay'),
            rotate: tr('Xoay'),
            flip: tr('Lật'),
            ratio: tr('Tỉ lệ'),
            back: tr('Quay lại'),
            done: tr('Xong'),
            cancel: tr('Hủy'),
            undo: tr('Hoàn tác'),
            redo: tr('Làm lại'),
            reset: tr('Đặt lại'),
            smallScreenMoreTooltip: tr('Thêm'),
          ),
          various: I18nVarious(
            loadingDialogMsg: tr('Vui lòng chờ...'),
            closeEditorWarningTitle: tr('Bỏ các thay đổi?'),
            closeEditorWarningMessage: tr('Ảnh sẽ không được lưu.'),
            closeEditorWarningConfirmBtn: tr('Bỏ'),
            closeEditorWarningCancelBtn: tr('Tiếp tục sửa'),
          ),
        ),
      ),
      callbacks: ProImageEditorCallbacks(
        onImageEditingComplete: (bytes) async {
          result = bytes;
          Navigator.of(ctx).pop();
        },
      ),
    ),
  ));
  if (result == null) return null;
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/edit_${DateTime.now().millisecondsSinceEpoch}.jpg');
  await f.writeAsBytes(result!);
  return f.path;
}
