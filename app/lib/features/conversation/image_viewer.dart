/// 图片全屏放大（第 8 轮 T04；架构裁定 7：点击放大本期做）。
///
/// 全屏深色遮罩 + `InteractiveViewer`（双指/滚轮缩放、拖拽平移）+ 顶部关闭按钮；
/// 左上角显示文件名。Esc 关闭（桌面语义）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
// 键盘事件 API（material.dart 不导出 services.dart，按需显式导入；
// 与 conversation_view.dart 同款做法）。
import 'package:flutter/services.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';

/// 全屏图片查看器。
class ImageViewer extends StatefulWidget {
  const ImageViewer({
    super.key,
    required this.path,
    required this.fileName,
  });

  final String path;

  final String fileName;

  /// 以对话框形式打开全屏查看器。
  static Future<void> show(
    BuildContext context, {
    required String path,
    required String fileName,
  }) =>
      showDialog<void>(
        context: context,
        barrierColor: Colors.black87,
        builder: (_) => ImageViewer(path: path, fileName: fileName),
      );

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final TransformationController _transform = TransformationController();

  /// 键盘监听焦点节点（Esc 关闭）。
  final FocusNode _keyFocus = FocusNode(debugLabel: 'image-viewer');

  @override
  void dispose() {
    _transform.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  void _reset() => _transform.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    final file = File(widget.path);
    // KeyboardListener.onKeyEvent 签名 = `ValueChanged<KeyEvent>?`
    // （SDK widgets/keyboard_listener.dart L58：**不是** `KeyEventResult`
    //  的处理器）——本处只用它做 Esc 关闭。
    return KeyboardListener(
      focusNode: _keyFocus,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
      child: Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(AppDims.space6),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                // 双击复位（避免缩放后"回不去"）。
                onDoubleTap: _reset,
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 0.8,
                  maxScale: 8,
                  child: Center(
                    child: file.existsSync()
                        ? Image.file(
                            file,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const _BrokenImage(),
                          )
                        : const _BrokenImage(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _TopBar(fileName: widget.fileName, onClose: _close),
            ),
          ],
        ),
      ),
    );
  }

  void _close() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.fileName, required this.onClose});

  final String fileName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: AppDims.space2),
        Expanded(
          child: Text(
            fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 48, color: AppColors.textTertiary),
        SizedBox(height: 8),
        Text('图片无法显示',
            style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
      ],
    );
  }
}

