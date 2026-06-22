import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Экран сканера QR: возвращает (Navigator.pop) распознанный текст QR.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        _handled = true;
        Navigator.pop(context, v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сканируйте QR десктопа')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(onDetect: _onDetect),
          // рамка-подсказка
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const Positioned(
            bottom: 40,
            child: Text('Наведите камеру на QR в настройках синхронизации десктопа',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, backgroundColor: Colors.black54)),
          ),
        ],
      ),
    );
  }
}
