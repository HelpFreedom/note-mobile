// Экраны ПИН-кода на Flutter (зеркало qtnotes/ui/pin_dialog.py): ввод (numpad + точки),
// настройка при первом включении, разблокировка при старте с обратным отсчётом блокировки.

import 'dart:async';

import 'package:flutter/material.dart';

import '../crypto/keyvault.dart' as kv;
import 'theme.dart';

const int _pinLen = 5;

/// Поле ввода ПИН: точки + numpad. Эмитит onCompleted при наборе 5 цифр.
class PinPad extends StatefulWidget {
  final void Function(String pin) onCompleted;
  const PinPad({super.key, required this.onCompleted});

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _pin = '';
  String _status = '';
  bool _padEnabled = true;

  void reset() => setState(() => _pin = '');
  void setStatus(String s) => setState(() => _status = s);
  void setPadEnabled(bool on) => setState(() => _padEnabled = on);

  void _add(String d) {
    if (!_padEnabled || _pin.length >= _pinLen) return;
    setState(() {
      _status = '';
      _pin += d;
    });
    if (_pin.length == _pinLen) {
      final pin = _pin;
      Future.delayed(const Duration(milliseconds: 60), () {
        if (!mounted) return;
        setState(() => _pin = '');
        widget.onCompleted(pin);
      });
    }
  }

  void _backspace() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dots(),
        const SizedBox(height: 14),
        SizedBox(
          height: 20,
          child: Text(_status,
              style: const TextStyle(color: AppColors.danger, fontSize: 13)),
        ),
        const SizedBox(height: 14),
        _numpad(),
      ],
    );
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLen, (i) {
        final filled = i < _pin.length;
        return Container(
          width: 16,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: filled ? AppColors.accent : Colors.transparent,
            shape: BoxShape.circle,
            border: filled ? null : Border.all(color: AppColors.textSecondary, width: 2),
          ),
        );
      }),
    );
  }

  Widget _numpad() {
    Widget btn(String label, {VoidCallback? onTap, bool digit = true}) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 68,
          height: 68,
          child: Material(
            color: AppColors.field,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _padEnabled ? onTap : null,
              child: Center(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 24,
                        color: _padEnabled ? AppColors.text : AppColors.textSecondary)),
              ),
            ),
          ),
        ),
      );
    }

    final rows = <Widget>[];
    for (var r = 0; r < 3; r++) {
      rows.add(Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(3, (cIdx) {
          final n = '${r * 3 + cIdx + 1}';
          return btn(n, onTap: () => _add(n));
        }),
      ));
    }
    rows.add(Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(width: 84),
        btn('0', onTap: () => _add('0')),
        btn('⌫', onTap: _backspace, digit: false),
      ],
    ));
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// Экран настройки ПИНа: ввод + подтверждение. Возвращает ПИН через Navigator.pop.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final _padKey = GlobalKey<PinPadState>();
  String _prompt = 'Придумайте 5-значный ПИН';
  String? _first;

  void _onCompleted(String pin) {
    final pad = _padKey.currentState!;
    if (_first == null) {
      try {
        kv.validatePin(pin);
      } on kv.PinError catch (e) {
        pad.reset();
        pad.setStatus(e.message);
        return;
      }
      setState(() {
        _first = pin;
        _prompt = 'Повторите ПИН';
      });
      pad.reset();
    } else {
      if (pin != _first) {
        setState(() {
          _first = null;
          _prompt = 'Придумайте 5-значный ПИН';
        });
        pad.reset();
        pad.setStatus('ПИН не совпал — попробуйте снова');
        return;
      }
      Navigator.of(context).pop(pin);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Создание ПИН-кода')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_prompt, style: const TextStyle(fontSize: 16).copyWith(color: AppColors.text)),
            const SizedBox(height: 24),
            PinPad(key: _padKey, onCompleted: _onCompleted),
          ],
        ),
      ),
    );
  }
}

/// Экран одиночного ввода ПИНа (для подтверждения действия). Возвращает ПИН через pop.
class PinEntryScreen extends StatelessWidget {
  final String title;
  const PinEntryScreen({super.key, this.title = 'Введите ПИН'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: PinPad(onCompleted: (pin) => Navigator.of(context).pop(pin)),
      ),
    );
  }
}

/// Экран разблокировки. check(pin) -> UnlockResult; remaining() -> сек блокировки.
/// При OK закрывается через onUnlocked. Esc/назад не выходят (гейт).
class PinUnlockScreen extends StatefulWidget {
  final Future<kv.UnlockResult> Function(String pin) check;
  final Future<int> Function() remaining;
  final VoidCallback onUnlocked;
  const PinUnlockScreen({
    super.key,
    required this.check,
    required this.remaining,
    required this.onUnlocked,
  });

  @override
  State<PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends State<PinUnlockScreen> {
  final _padKey = GlobalKey<PinPadState>();
  Timer? _lockTimer; // единственный отсчёт блокировки (отменяемый)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshLock());
  }

  @override
  void dispose() {
    _lockTimer?.cancel(); // не оставлять тикающий таймер после удаления экрана
    super.dispose();
  }

  Future<void> _refreshLock() async {
    if (await widget.remaining() > 0) _startLock();
  }

  Future<void> _onCompleted(String pin) async {
    final res = await widget.check(pin);
    if (!mounted) return;
    _padKey.currentState?.reset();
    if (res.status == kv.UnlockStatus.ok) {
      widget.onUnlocked();
    } else if (res.status == kv.UnlockStatus.locked) {
      _startLock();
    } else {
      if (await widget.remaining() > 0) {
        _startLock();
      } else {
        _padKey.currentState?.setStatus('Неверный ПИН');
      }
    }
  }

  void _startLock() {
    _padKey.currentState?.setPadEnabled(false);
    _lockTimer?.cancel(); // не плодить параллельные циклы отсчёта
    _tick(); // показать сразу
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    final left = await widget.remaining();
    if (!mounted) {
      _lockTimer?.cancel();
      return;
    }
    if (left <= 0) {
      _lockTimer?.cancel();
      _lockTimer = null;
      _padKey.currentState?.setPadEnabled(true);
      _padKey.currentState?.setStatus('');
      return;
    }
    final m = (left ~/ 60).toString().padLeft(2, '0');
    final s = (left % 60).toString().padLeft(2, '0');
    _padKey.currentState?.setStatus('Слишком много попыток. Повторите через $m:$s');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // гейт: системная «назад» не закрывает
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 48, color: AppColors.textSecondary),
                const SizedBox(height: 16),
                Text('Введите ПИН',
                    style: const TextStyle(fontSize: 18).copyWith(color: AppColors.text)),
                const SizedBox(height: 24),
                PinPad(key: _padKey, onCompleted: _onCompleted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
