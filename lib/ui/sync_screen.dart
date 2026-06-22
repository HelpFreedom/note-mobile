import 'package:flutter/material.dart';

import '../app/app_service.dart';
import '../sync/peers.dart';
import 'pin_screen.dart';
import 'qr_scan_screen.dart';
import 'theme.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  List<Peer> _devices = [];
  bool _canBiometric = false;
  bool _biometricOn = false;

  @override
  void initState() {
    super.initState();
    appService.addListener(_refresh);
    _loadDevices();
    _loadBiometric();
  }

  @override
  void dispose() {
    appService.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
    _loadDevices();
    _loadBiometric();
  }

  Future<void> _loadDevices() async {
    final d = await appService.pairedDevices();
    if (mounted) setState(() => _devices = d);
  }

  Future<void> _loadBiometric() async {
    final can = await appService.canDeviceAuth();
    final on = await appService.biometricEnabled();
    if (mounted) {
      setState(() {
        _canBiometric = can;
        _biometricOn = on;
      });
    }
  }

  Future<void> _toggleBiometric(bool enable) async {
    if (!appService.encryptionConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Сначала включите локальное шифрование')));
      return;
    }
    final pin = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (_) => const PinEntryScreen(title: 'Подтвердите ПИН')));
    if (pin == null || !mounted) return;
    try {
      final ok = await appService.setBiometric(enable, pin);
      if (!mounted) return;
      if (ok) {
        setState(() => _biometricOn = enable);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(enable
                ? 'Биометрия включена — теперь нужна при разблокировке'
                : 'Биометрия выключена')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Неверный ПИН или отмена')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось: $e')));
      }
    }
  }

  Future<void> _scanQr() async {
    final payload = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (payload != null) await _doPair(payload);
  }

  Future<void> _pairManually() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.appBar,
        title: const Text('Данные QR с десктопа'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Вставьте текст из QR'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Сопрячь')),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) await _doPair(text);
  }

  Future<void> _doPair(String text) async {
    try {
      await appService.pairFromQr(text);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Устройство сопряжено')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось сопрячь: $e')));
      }
    }
  }

  Future<void> _openEncryption() async {
    if (appService.encryptionConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Шифрование включено. ПИН запрашивается при запуске.')));
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.appBar,
        title: const Text('Включить шифрование?'),
        content: const Text(
            'ПИН задаётся сейчас и потребуется при каждом запуске.\n\n'
            'Восстановления ПИНа НЕТ: забыли — данные на этом устройстве недоступны '
            '(восстановление со второго устройства). Существующие данные будут '
            'зашифрованы, перед этим создаётся резервная копия.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Включить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final pin = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const PinSetupScreen()));
    if (pin == null || !mounted) return;

    // прогресс на время фоновой миграции (шифрование может занять время на крупных вложениях)
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.appBar,
          content: const Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Шифрование данных…')),
            ],
          ),
        ),
      ),
    );
    try {
      final stats = await appService.enableEncryption(pin);
      if (mounted) Navigator.pop(context); // закрыть прогресс
      if (!mounted) return;
      setState(() {});
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.appBar,
          title: const Text('Готово'),
          content: Text(
              'Шифрование включено, данные зашифрованы.\n'
              'Папок: ${stats['folders']}, заметок: ${stats['notes']}, '
              'вложений: ${stats['blobs']}.\n\n'
              'Временная резервная копия (плейнтекст) удалена после перешифровки.\n'
              'Перезапустите приложение — ПИН будет запрашиваться при старте.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context); // закрыть прогресс
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось включить: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = appService.identity;
    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Синхронизация по локальной сети'),
            subtitle: Text(appService.syncStatus),
            value: appService.syncEnabled,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => appService.setSyncEnabled(v),
          ),
          const Divider(height: 1, color: AppColors.divider),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Локальное шифрование (ПИН)'),
            subtitle: Text(appService.encryptionConfigured ? 'включено' : 'выключено'),
            onTap: _openEncryption,
          ),
          if (appService.encryptionConfigured && _canBiometric)
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Биометрия / код устройства'),
              subtitle: const Text('Аппаратная защита: нужна при разблокировке. '
                  'Стойко против перебора даже с root.'),
              value: _biometricOn,
              activeThumbColor: AppColors.accent,
              onChanged: _toggleBiometric,
            ),
          const Divider(height: 1, color: AppColors.divider),
          ListTile(
            title: Text('Это устройство: ${id.name}'),
            subtitle: Text('ID: ${id.deviceId}'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Сканировать QR десктопа'),
              onPressed: appService.syncEnabled
                  ? _scanQr
                  : () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Сначала включите синхронизацию'))),
            ),
          ),
          if (appService.syncEnabled)
            Center(
              child: TextButton(
                onPressed: _pairManually,
                child: const Text('Ввести данные вручную'),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Сопряжённые устройства:',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          if (_devices.isEmpty)
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('Пока нет', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ..._devices.map((p) => ListTile(
                leading: const Icon(Icons.devices),
                title: Text(p.name.isEmpty ? '—' : p.name),
                subtitle: Text(p.deviceId),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: AppColors.danger),
                  onPressed: () => appService.removePeer(p.deviceId),
                ),
              )),
        ],
      ),
    );
  }
}
