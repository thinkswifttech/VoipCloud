import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../shared/icons/app_icons.dart';
import '../../../shared/platform/desktop_platform.dart';
import '../domain/provisioning_activation_input.dart';
import '../domain/provisioning_qr_image_decoder.dart';

class ProvisioningScannerScreen extends StatefulWidget {
  const ProvisioningScannerScreen({super.key});

  @override
  State<ProvisioningScannerScreen> createState() =>
      _ProvisioningScannerScreenState();
}

class _ProvisioningScannerScreenState extends State<ProvisioningScannerScreen> {
  MobileScannerController? _scannerController;

  bool _didReturn = false;
  bool _dragging = false;
  bool _isReadingFile = false;
  String? _statusText;

  bool get _usesDesktopImporter => isSupportedDesktopPlatform();

  @override
  void initState() {
    super.initState();
    if (!_usesDesktopImporter) {
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.qrCode],
      );
    }
  }

  @override
  void dispose() {
    final scannerController = _scannerController;
    if (scannerController != null) {
      unawaited(scannerController.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_usesDesktopImporter) {
      return _buildDesktopImporter(context);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan activation QR'),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Paste instead'),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 820;
          final scanner = Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _scannerController!,
                fit: BoxFit.cover,
                onDetect: _handleScan,
                errorBuilder: (context, error) {
                  return _ScannerError(
                    message:
                        error.errorDetails?.message ?? 'Camera unavailable.',
                  );
                },
                placeholderBuilder: (context) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                },
              ),
              const _ScannerFrame(),
              Positioned(
                left: 20,
                right: 20,
                bottom: 28,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(
                          _statusText == null
                              ? AppIcons.scan
                              : AppIcons.warning,
                          color: _statusText == null
                              ? Colors.white
                              : theme.colorScheme.error,
                          size: AppIconSize.md,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _statusText ??
                                'Position the activation QR in frame.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );

          if (!isWide) {
            return scanner;
          }

          return ColoredBox(
            color: Colors.black,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 720,
                  maxHeight: 720,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(aspectRatio: 3 / 4, child: scanner),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleScan(BarcodeCapture capture) async {
    if (_didReturn) {
      return;
    }

    final rawValue = _firstValue(capture);
    if (rawValue == null) {
      return;
    }

    await _acceptPayload(rawValue, stopCamera: true);
  }

  Widget _buildDesktopImporter(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import activation QR'),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Paste instead'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: DropTarget(
              onDragEntered: (_) {
                if (!_isReadingFile) setState(() => _dragging = true);
              },
              onDragExited: (_) {
                if (_dragging) setState(() => _dragging = false);
              },
              onDragDone: (details) {
                setState(() => _dragging = false);
                unawaited(_handleDroppedFiles(details.files));
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(42, 52, 42, 46),
                decoration: BoxDecoration(
                  color: _dragging
                      ? theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.46,
                        )
                      : theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _dragging
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                    width: _dragging ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isReadingFile)
                      const SizedBox(
                        width: 48,
                        height: 48,
                        child: CircularProgressIndicator(),
                      )
                    else
                      Icon(
                        AppIcons.qrCode,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                    const SizedBox(height: 22),
                    Text(
                      _isReadingFile
                          ? 'Reading QR code…'
                          : _dragging
                          ? 'Drop the QR image here'
                          : 'Drag your downloaded QR code here',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Use a PNG, JPEG, or WebP image. The file is processed '
                      'locally and is not uploaded.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _isReadingFile ? null : _chooseImage,
                      icon: const Icon(AppIcons.gallery),
                      label: const Text('Choose QR image'),
                    ),
                    if (_statusText != null) ...[
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            AppIcons.warning,
                            color: theme.colorScheme.error,
                            size: AppIconSize.md,
                          ),
                          const SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              _statusText!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _chooseImage() async {
    const typeGroup = XTypeGroup(
      label: 'QR code images',
      extensions: ['png', 'jpg', 'jpeg', 'webp'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file != null) {
      await _readQrFile(file);
    }
  }

  Future<void> _handleDroppedFiles(List<XFile> files) async {
    if (files.length != 1) {
      _showStatus('Drop one QR code image at a time.');
      return;
    }
    await _readQrFile(files.single);
  }

  Future<void> _readQrFile(XFile file) async {
    if (_isReadingFile || _didReturn) return;

    final extension = file.name.split('.').last.toLowerCase();
    if (!const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
      _showStatus('Choose a PNG, JPEG, or WebP image.');
      return;
    }

    setState(() {
      _isReadingFile = true;
      _statusText = null;
    });

    try {
      final length = await file.length();
      if (length <= 0 || length > maximumProvisioningQrFileBytes) {
        _showStatus('Choose an image smaller than 12 MB.');
        return;
      }

      final rawValue = await decodeProvisioningQrImage(
        await file.readAsBytes(),
      );
      if (rawValue == null) {
        _showStatus('No readable QR code was found in this image.');
        return;
      }
      await _acceptPayload(rawValue);
    } catch (error, stackTrace) {
      debugPrint('Provisioning QR import failed: $error\n$stackTrace');
      _showStatus('This image could not be read. Try another file.');
    } finally {
      if (mounted && !_didReturn) {
        setState(() => _isReadingFile = false);
      }
    }
  }

  Future<void> _acceptPayload(
    String rawValue, {
    bool stopCamera = false,
  }) async {
    if (_didReturn) return;
    if (!isProvisioningActivationInput(rawValue)) {
      _showStatus('This QR code is not a VoipCloud activation link.');
      return;
    }

    _didReturn = true;
    if (stopCamera) {
      await _scannerController?.stop();
    }
    if (mounted) context.pop(rawValue);
  }

  void _showStatus(String message) {
    if (!mounted) return;
    setState(() {
      _statusText = message;
      _isReadingFile = false;
    });
  }
}

String? _firstValue(BarcodeCapture capture) {
  for (final barcode in capture.barcodes) {
    final value = barcode.rawValue?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

class _ScannerFrame extends StatelessWidget {
  const _ScannerFrame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: FractionallySizedBox(
          widthFactor: 0.72,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.warning, color: theme.colorScheme.error, size: 34),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
