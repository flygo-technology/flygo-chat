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
      configs: const ProImageEditorConfigs(
        designMode: ImageEditorDesignMode.cupertino,
        mainEditor: MainEditorConfigs(tools: [SubEditorMode.paint, SubEditorMode.cropRotate]),
        i18n: I18n(
          cancel: 'Hủy',
          undo: 'Hoàn tác',
          redo: 'Làm lại',
          done: 'Xong',
          remove: 'Xóa',
          doneLoadingMsg: 'Đang lưu ảnh...',
          paintEditor: I18nPaintEditor(
            bottomNavigationBarText: 'Vẽ',
            freestyle: 'Vẽ tự do',
            arrow: 'Mũi tên',
            line: 'Đường thẳng',
            rectangle: 'Hình chữ nhật',
            circle: 'Hình tròn',
            dashLine: 'Nét đứt',
            lineWidth: 'Độ dày nét',
            eraser: 'Tẩy',
            toggleFill: 'Tô đặc',
            changeOpacity: 'Độ mờ',
            undo: 'Hoàn tác',
            redo: 'Làm lại',
            done: 'Xong',
            back: 'Quay lại',
            smallScreenMoreTooltip: 'Thêm',
            moveAndZoom: 'Phóng to',
          ),
          cropRotateEditor: I18nCropRotateEditor(
            bottomNavigationBarText: 'Cắt / Xoay',
            rotate: 'Xoay',
            flip: 'Lật',
            ratio: 'Tỉ lệ',
            back: 'Quay lại',
            done: 'Xong',
            cancel: 'Hủy',
            undo: 'Hoàn tác',
            redo: 'Làm lại',
            reset: 'Đặt lại',
            smallScreenMoreTooltip: 'Thêm',
          ),
          various: I18nVarious(
            loadingDialogMsg: 'Vui lòng chờ...',
            closeEditorWarningTitle: 'Bỏ các thay đổi?',
            closeEditorWarningMessage: 'Ảnh sẽ không được lưu.',
            closeEditorWarningConfirmBtn: 'Bỏ',
            closeEditorWarningCancelBtn: 'Tiếp tục sửa',
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
