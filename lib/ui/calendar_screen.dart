import 'package:flutter/material.dart';

import '../app/app_service.dart';
import '../storage/models.dart';
import 'theme.dart';
import 'widgets/confirm.dart';

const _months = [
  'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь',
  'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь',
];
const _weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];

String _two(int n) => n.toString().padLeft(2, '0');
String _dateKey(int y, int m, int d) => '$y-${_two(m)}-${_two(d)}';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  Map<String, List<Event>> _byDate = {};

  @override
  void initState() {
    super.initState();
    appService.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    appService.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final events = await appService.events();
    final map = <String, List<Event>>{};
    for (final e in events) {
      map.putIfAbsent(e.date, () => []).add(e);
    }
    if (mounted) setState(() => _byDate = map);
  }

  void _prevMonth() => setState(() => _month = DateTime(_month.year, _month.month - 1, 1));
  void _nextMonth() => setState(() => _month = DateTime(_month.year, _month.month + 1, 1));

  Color _color(String hex) {
    if (hex.startsWith('#') && hex.length == 7) {
      return Color(int.parse('FF${hex.substring(1)}', radix: 16));
    }
    return AppColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = DateTime(_month.year, _month.month, 1).weekday - 1; // Пн=0
    final totalCells = ((leading + daysInMonth) / 7).ceil() * 7;
    final today = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Календарь')),
      body: Column(
        children: [
          // заголовок месяца
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(onPressed: _prevMonth, icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text('${_months[_month.month - 1]} ${_month.year}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.text, fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                IconButton(onPressed: _nextMonth, icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          Row(
            children: _weekdays
                .map((w) => Expanded(
                    child: Center(
                        child: Text(w,
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 12)))))
                .toList(),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 0.62,
              ),
              itemCount: totalCells,
              itemBuilder: (ctx, index) {
                final dayNum = index - leading + 1;
                if (dayNum < 1 || dayNum > daysInMonth) {
                  return const SizedBox.shrink();
                }
                final key = _dateKey(_month.year, _month.month, dayNum);
                final events = _byDate[key] ?? const [];
                final isToday = today.year == _month.year &&
                    today.month == _month.month &&
                    today.day == dayNum;
                return _DayCell(
                  day: dayNum,
                  isToday: isToday,
                  events: events,
                  colorOf: _color,
                  onTap: () => _daySheet(key, dayNum),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _daySheet(String dateKey, int day) {
    final events = _byDate[dateKey] ?? const <Event>[];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.appBar,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('${_months[_month.month - 1]} $day, ${_month.year}',
                  style: TextStyle(
                      color: AppColors.text, fontWeight: FontWeight.w600)),
            ),
            ...events.map((e) => ListTile(
                  leading: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                          color: _color(e.color), shape: BoxShape.circle)),
                  title: Text(e.name),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: AppColors.danger),
                    onPressed: () async {
                      final ok = await confirmDelete(
                        context,
                        title: 'Удалить событие',
                        message: 'Удалить событие «${e.name}»?',
                      );
                      if (!ok) return;
                      await appService.deleteEvent(e.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                  ),
                )),
            ListTile(
              leading: Icon(Icons.add, color: AppColors.accent),
              title: const Text('Добавить событие'),
              onTap: () {
                Navigator.pop(ctx);
                _addEvent(dateKey);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addEvent(String dateKey) async {
    final nameController = TextEditingController();
    var colorIndex = 0;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.appBar,
          title: const Text('Новое событие'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Название'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: List.generate(AppColors.eventColors.length, (i) {
                  return GestureDetector(
                    onTap: () => setLocal(() => colorIndex = i),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: AppColors.eventColors[i],
                        shape: BoxShape.circle,
                        border: i == colorIndex
                            ? Border.all(color: Colors.white, width: 2)
                            : null,
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
                child: const Text('Создать')),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    final hex =
        '#${AppColors.eventColors[colorIndex].toARGB32().toRadixString(16).substring(2)}';
    await appService.addEvent(dateKey, name, hex);
  }
}

class _DayCell extends StatelessWidget {
  final int day;
  final bool isToday;
  final List<Event> events;
  final Color Function(String) colorOf;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.isToday,
    required this.events,
    required this.colorOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.bubbleAlt.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: isToday ? Border.all(color: AppColors.accent, width: 1.5) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$day',
                style: TextStyle(
                    color: isToday ? AppColors.accent : AppColors.text,
                    fontSize: 13,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal)),
            const SizedBox(height: 2),
            ...events.take(3).map((e) => Container(
                  margin: const EdgeInsets.only(bottom: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: colorOf(e.color),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  width: double.infinity,
                  child: Text(e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 9)),
                )),
            if (events.length > 3)
              Text('+${events.length - 3}',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 9)),
          ],
        ),
      ),
    );
  }
}
