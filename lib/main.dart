import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_service.dart';
import 'crypto/blob_crypto.dart';
import 'crypto/native_aes.dart';
import 'ui/folders_screen.dart';
import 'ui/pin_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // подключить нативный (аппаратный) AES для blob-крипто — в сотни раз быстрее pure-Dart
  BlobCrypto.nativeEncrypt = NativeAes.encrypt;
  BlobCrypto.nativeDecrypt = NativeAes.decrypt;
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory('${docs.path}/QtNotes');
  await root.create(recursive: true);
  // G2: расшифрованный кэш медиа — в app-private cache (внутри backup-excluded домена),
  // а не в systemTemp (зависимость от TMPDIR).
  final cache = await getApplicationCacheDirectory();
  appService = AppService(root, cacheRoot: cache);
  await appService.init();
  runApp(const QtNotesApp());
}

class QtNotesApp extends StatefulWidget {
  const QtNotesApp({super.key});

  @override
  State<QtNotesApp> createState() => _QtNotesAppState();
}

class _QtNotesAppState extends State<QtNotesApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    appService.addListener(_onChange); // тема может прийти с десктопа
    WidgetsBinding.instance.addObserver(this); // G1: реагировать на уход в фон
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appService.removeListener(_onChange);
    super.dispose();
  }

  // G1 (раунд-3): при сворачивании/закрытии — заблокировать (забыть MK, стереть кэш
  // плейнтекста). На resume build() покажет PIN-гейт (appService.isLocked).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      appService.lockForBackground();
    } else if (state == AppLifecycleState.resumed) {
      // внешняя активность (пикер/шаринг) завершена — сбросить счётчик подавления как
      // страховку от утёкшего begin (иначе авто-lock мог бы отключиться навсегда).
      appService.onResumed();
    }
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Note',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // гейт: если шифрование настроено и приложение заблокировано — экран ПИНа до
      // показа данных (заметки/индекс читаются из расшифрованного хранилища).
      home: appService.isLocked
          ? PinUnlockScreen(
              check: appService.tryUnlock,
              remaining: appService.unlockRemaining,
              onUnlocked: () {},
            )
          : const FoldersScreen(),
    );
  }
}
