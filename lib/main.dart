import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

/// ======================
/// THEME
/// ======================
ThemeData buildTheme() {
  final base = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00BFA6)),
    useMaterial3: true,
  );
  return base.copyWith(
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
      filled: true,
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// ======================
/// APP ROOT
/// ======================
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => TodoProvider(TodoRepository())..load(),
      child: MaterialApp(
        title: 'To-Do Pro',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomePage(),
      ),
    );
  }
}

/// ======================
/// MODEL
/// ======================
enum Priority { low, medium, high }

class Todo {
  final String id;
  final String title;
  final bool isDone;
  final DateTime createdAt;
  final DateTime? deadline;
  final Priority priority;

  const Todo({
    required this.id,
    required this.title,
    required this.createdAt,
    this.isDone = false,
    this.deadline,
    this.priority = Priority.medium,
  });

  Todo copyWith({
    String? title,
    bool? isDone,
    DateTime? deadline,
    Priority? priority,
  }) => Todo(
    id: id,
    title: title ?? this.title,
    isDone: isDone ?? this.isDone,
    createdAt: createdAt,
    deadline: deadline ?? this.deadline,
    priority: priority ?? this.priority,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'isDone': isDone,
    'createdAt': createdAt.toIso8601String(),
    'deadline': deadline?.toIso8601String(),
    'priority': priority.name,
  };

  factory Todo.fromMap(Map<String, dynamic> map) => Todo(
    id: map['id'] as String,
    title: map['title'] as String,
    isDone: map['isDone'] as bool,
    createdAt: DateTime.parse(map['createdAt'] as String),
    deadline: (map['deadline'] as String?) != null
        ? DateTime.parse(map['deadline'] as String)
        : null,
    priority: Priority.values.firstWhere(
      (e) => e.name == (map['priority'] as String? ?? 'medium'),
      orElse: () => Priority.medium,
    ),
  );

  String toJson() => jsonEncode(toMap());
  factory Todo.fromJson(String source) => Todo.fromMap(jsonDecode(source));
}

/// ======================
/// REPOSITORY
/// ======================
class TodoRepository {
  static const String _key = 'todos_v3_deadline_priority';

  Future<List<Todo>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? <String>[];
    return raw.map(Todo.fromJson).toList();
  }

  Future<void> save(List<Todo> todos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, todos.map((e) => e.toJson()).toList());
  }
}

/// ======================
/// PROVIDER
/// ======================
enum Filter { all, active, done }

class TodoProvider extends ChangeNotifier {
  TodoProvider(this._repo);
  final TodoRepository _repo;
  final _rand = Random();

  List<Todo> _items = <Todo>[];
  String _query = '';
  Filter _filter = Filter.all;

  // undo buffer
  Todo? _lastDeleted;
  int? _lastDeletedIndex;

  List<Todo> get items {
    Iterable<Todo> list = _items;
    if (_query.isNotEmpty) {
      list = list.where((t) => t.title.toLowerCase().contains(_query));
    }
    switch (_filter) {
      case Filter.active:
        list = list.where((t) => !t.isDone);
        break;
      case Filter.done:
        list = list.where((t) => t.isDone);
        break;
      case Filter.all:
        break;
    }
    final now = DateTime.now();

    // Sort: Active first by (deadline asc, priority desc, createdAt asc)
    // Done at bottom by completed time (we don't store it; fallback to createdAt)
    final res = list.toList()
      ..sort((a, b) {
        // done to the bottom
        if (a.isDone != b.isDone) return a.isDone ? 1 : -1;

        // both active: nearest deadline first (nulls last)
        final aHas = a.deadline != null;
        final bHas = b.deadline != null;
        if (aHas != bHas) return aHas ? -1 : 1;
        if (a.deadline != null && b.deadline != null) {
          final d = a.deadline!.compareTo(b.deadline!);
          if (d != 0) return d;
        }

        // priority: high > medium > low
        final pr = b.priority.index.compareTo(a.priority.index);
        if (pr != 0) return pr;

        // earlier created first
        return a.createdAt.compareTo(b.createdAt);
      });

    // Gentle nudge for overdue (keep within active order above)
    res.sort((a, b) {
      if (a.isDone || b.isDone) return 0;
      final aOver = a.deadline != null && a.deadline!.isBefore(now);
      final bOver = b.deadline != null && b.deadline!.isBefore(now);
      if (aOver == bOver) return 0;
      return aOver ? -1 : 1;
    });

    return res;
  }

  Filter get filter => _filter;
  int get remaining => _items.where((t) => !t.isDone).length;

  Future<void> load() async {
    _items = await _repo.load();
    notifyListeners();
  }

  Future<void> _persist() async => _repo.save(_items);

  Future<void> add({
    required String title,
    DateTime? deadline,
    Priority priority = Priority.medium,
  }) async {
    final clean = title.trim();
    if (clean.isEmpty) return;
    final id =
        '${DateTime.now().millisecondsSinceEpoch}-${_rand.nextInt(99999)}';
    _items.add(
      Todo(
        id: id,
        title: clean,
        createdAt: DateTime.now(),
        deadline: deadline,
        priority: priority,
      ),
    );
    notifyListeners();
    await _persist();
  }

  Future<void> toggle(String id) async {
    final idx = _items.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    _items[idx] = _items[idx].copyWith(isDone: !_items[idx].isDone);
    notifyListeners();
    await _persist();
  }

  Future<void> edit({
    required String id,
    required String title,
    DateTime? deadline,
    Priority? priority,
  }) async {
    final clean = title.trim();
    if (clean.isEmpty) return;
    final idx = _items.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    _items[idx] = _items[idx].copyWith(
      title: clean,
      deadline: deadline,
      priority: priority,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    final idx = _items.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    _lastDeleted = _items[idx];
    _lastDeletedIndex = idx;
    _items.removeAt(idx);
    notifyListeners();
    await _persist();
  }

  Future<void> undoDelete() async {
    if (_lastDeleted == null || _lastDeletedIndex == null) return;
    final i = _lastDeletedIndex!.clamp(0, _items.length);
    _items.insert(i, _lastDeleted!);
    _lastDeleted = null;
    _lastDeletedIndex = null;
    notifyListeners();
    await _persist();
  }

  Future<void> clearCompleted() async {
    _items.removeWhere((t) => t.isDone);
    notifyListeners();
    await _persist();
  }

  void setQuery(String q) {
    _query = q.toLowerCase();
    notifyListeners();
  }

  void setFilter(Filter f) {
    _filter = f;
    notifyListeners();
  }
}

/// ======================
/// UI
/// ======================
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      extendBody: true,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: const _FancyFAB(),
      bottomNavigationBar: const _BottomBarCurve(),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF001510), Color(0xFF00BFA6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                snap: true,
                backgroundColor: Colors.transparent,
                flexibleSpace: _Header(),
                expandedHeight: 170,
                toolbarHeight: 0,
                actions: [
                  IconButton(
                    tooltip: 'Clear completed',
                    onPressed: () =>
                        context.read<TodoProvider>().clearCompleted(),
                    icon: const Icon(
                      Icons.cleaning_services_outlined,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _SearchBar(),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              const SliverToBoxAdapter(child: _FilterChips()),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              const _TodoListSliver(),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  child: Builder(
                    builder: (context) {
                      final remaining = context.watch<TodoProvider>().remaining;
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surface.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: cs.onSurface.withValues(alpha: .12),
                            ),
                          ),
                          child: Text(
                            '$remaining tasks remaining',
                            style: TextStyle(color: cs.onSurface),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header gradien + glass card
class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: const [
        Positioned(top: -40, right: -30, child: _Bubble(size: 160)),
        Positioned(bottom: -30, left: -20, child: _Bubble(size: 200)),
        _HeaderCard(),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.white24,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(blurRadius: 40, color: Colors.black12)],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .12),
                border: Border.all(color: Colors.white.withValues(alpha: .2)),
                borderRadius: BorderRadius.circular(22),
              ),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: cs.onPrimary,
                  shadows: const [
                    Shadow(
                      blurRadius: 8,
                      color: Colors.black26,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Plan • Focus • Win', style: TextStyle(fontSize: 14)),
                    SizedBox(height: 6),
                    Text(
                      'To-Do Pro',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Search bar
class _SearchBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: context.read<TodoProvider>().setQuery,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        hintText: 'Search tasks…',
      ),
    );
  }
}

/// Filter chips
class _FilterChips extends StatelessWidget {
  const _FilterChips();
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TodoProvider>();
    final cs = Theme.of(context).colorScheme;

    ChoiceChip chip(String label, Filter value) {
      final selected = provider.filter == value;
      return ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) => context.read<TodoProvider>().setFilter(value),
        selectedColor: cs.primary.withValues(alpha: .2),
        labelStyle: TextStyle(
          color: selected ? cs.onPrimaryContainer : cs.onSurface,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        avatar: selected ? const Icon(Icons.check, size: 18) : null,
        side: BorderSide(color: cs.outline.withValues(alpha: .3)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        children: [
          chip('All', Filter.all),
          chip('Active', Filter.active),
          chip('Done', Filter.done),
        ],
      ),
    );
  }
}

/// Sliver list
class _TodoListSliver extends StatelessWidget {
  const _TodoListSliver();
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TodoProvider>();
    final items = provider.items;

    if (items.isEmpty) {
      return const SliverToBoxAdapter(child: _EmptyState());
    }

    return SliverList.separated(
      itemBuilder: (_, i) => _TodoCard(todo: items[i], index: i),
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemCount: items.length,
    );
  }
}

/// Card dengan deadline & priority
class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.todo, required this.index});
  final Todo todo;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isOverdue =
        todo.deadline != null && todo.deadline!.isBefore(DateTime.now());

    Color priorityColor(Priority p) {
      switch (p) {
        case Priority.high:
          return Colors.redAccent;
        case Priority.medium:
          return Colors.amber;
        case Priority.low:
          return Colors.lightGreen;
      }
    }

    return AnimatedPadding(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: index == 0 ? 12 : 0,
        bottom: 0,
      ),
      child: Dismissible(
        key: ValueKey(todo.id),
        background: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: cs.errorContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 24),
              child: Icon(Icons.delete_outline_rounded),
            ),
          ),
        ),
        onDismissed: (_) async {
          // Ambil dependensi sebelum await
          final prov = context.read<TodoProvider>();
          final messenger = ScaffoldMessenger.of(context);

          await prov.remove(todo.id);

          // Pakai messenger yang sudah dicapture
          messenger.showSnackBar(
            SnackBar(
              content: const Text('Task deleted'),
              action: SnackBarAction(
                label: 'UNDO',
                onPressed: () => prov.undoDelete(),
              ),
            ),
          );
        },

        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: 220 + (index * 40).clamp(0, 300)),
          builder: (_, t, child) => Transform.translate(
            offset: Offset(0, (1 - t) * 12),
            child: Opacity(opacity: t, child: child),
          ),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: todo.isDone
                      ? [
                          cs.secondaryContainer.withValues(alpha: .6),
                          cs.surface,
                        ]
                      : [cs.primaryContainer.withValues(alpha: .6), cs.surface],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: InkWell(
                onTap: () => context.read<TodoProvider>().toggle(todo.id),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedScale(
                        duration: const Duration(milliseconds: 200),
                        scale: todo.isDone ? 1.1 : 1,
                        child: Checkbox(
                          value: todo.isDone,
                          onChanged: (_) =>
                              context.read<TodoProvider>().toggle(todo.id),
                          shape: const StadiumBorder(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                decoration: todo.isDone
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: isOverdue && !todo.isDone
                                    ? Colors.redAccent
                                    : cs.onSurface,
                              ),
                              child: Text(
                                todo.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                if (todo.deadline != null)
                                  _Pill(
                                    icon: Icons.schedule,
                                    text: _deadlineLabel(todo.deadline!),
                                    bg: (isOverdue && !todo.isDone)
                                        ? Colors.redAccent.withValues(
                                            alpha: .18,
                                          )
                                        : cs.onSurfaceVariant.withValues(
                                            alpha: .5,
                                          ),
                                  ),
                                _Pill(
                                  icon: Icons.flag_rounded,
                                  text: _priorityText(todo.priority),
                                  bg: priorityColor(
                                    todo.priority,
                                  ).withValues(alpha: .18),
                                ),
                                _Pill(
                                  icon: Icons.bolt,
                                  text:
                                      'Created ${_friendlyTime(todo.createdAt)}',
                                  bg: cs.surface.withValues(alpha: .18),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      _CardActions(todo: todo),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _friendlyTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String _deadlineLabel(DateTime dt) {
    final now = DateTime.now();
    final diff = dt.difference(now);
    final d = diff.inDays;
    final h = diff.inHours;
    if (diff.inMinutes < 0) return 'Overdue • ${_dateTimeShort(dt)}';
    if (h < 1) return 'Due in ${diff.inMinutes}m';
    if (d < 1) return 'Due in ${h}h';
    if (d == 1) return 'Tomorrow • ${_timeShort(dt)}';
    return '${d}d • ${_dateShort(dt)}';
  }

  static String _dateShort(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}';
  static String _timeShort(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  static String _dateTimeShort(DateTime dt) =>
      '${_dateShort(dt)} ${_timeShort(dt)}';
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.bg});
  final IconData icon;
  final String text;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outline.withValues(alpha: .1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ],
      ),
    );
  }
}

String _priorityText(Priority p) {
  switch (p) {
    case Priority.high:
      return 'High';
    case Priority.medium:
      return 'Medium';
    case Priority.low:
      return 'Low';
  }
}

/// Action buttons (edit/delete)
class _CardActions extends StatelessWidget {
  const _CardActions({required this.todo});
  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconButton(
          tooltip: 'Edit',
          icon: Icons.edit_rounded,
          onTap: () => _showEdit(context),
        ),
        const SizedBox(width: 6),
        _IconButton(
          tooltip: 'Delete',
          icon: Icons.delete_outline_rounded,
          color: cs.error,
          onTap: () async {
            // Ambil dependensi sebelum await
            final prov = context.read<TodoProvider>();
            final messenger = ScaffoldMessenger.of(context);

            await prov.remove(todo.id);

            messenger.showSnackBar(
              SnackBar(
                content: const Text('Task deleted'),
                action: SnackBarAction(
                  label: 'UNDO',
                  onPressed: () => prov.undoDelete(),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _showEdit(BuildContext context) {
    // Capture dependency lebih dulu (aman dari "context across async gaps")
    final prov = context.read<TodoProvider>();

    _showTaskSheet(
      context,
      initialTitle: todo.title,
      initialDeadline: todo.deadline,
      initialPriority: todo.priority,

      // onSubmit harus async -> Future<void>
      onSubmit: (String title, DateTime? deadline, Priority priority) async {
        await prov.edit(
          id: todo.id,
          title: title,
          deadline: deadline,
          priority: priority,
        );
        return; // opsional, membuat intent jelas
      },
    );
  }
}

/// FAB add
class _FancyFAB extends StatelessWidget {
  const _FancyFAB();

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: () => _showTaskSheet(context),
      icon: const Icon(Icons.add),
      label: const Text('Add Task'),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.onTap,
    this.color,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.onSurface.withValues(alpha: .08)),
          ),
          child: Icon(icon, size: 20, color: color ?? cs.onSurface),
        ),
      ),
    );
  }
}

/// Empty state
class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primaryContainer.withValues(alpha: .35),
            ),
            child: Icon(
              Icons.inbox_outlined,
              size: 56,
              color: cs.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Semua beres!',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 18,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap tombol + di bawah untuk menambah tugas pertamamu.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface.withValues(alpha: .7)),
          ),
        ],
      ),
    );
  }
}

/// Bottom bar
class _BottomBarCurve extends StatelessWidget {
  const _BottomBarCurve();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 76,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: .22),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: cs.onSurface.withValues(alpha: .1)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ======================
/// Task Sheet (Add/Edit) with Deadline & Priority
/// ======================
Future<void> _showTaskSheet(
  BuildContext context, {
  String? initialTitle,
  DateTime? initialDeadline,
  Priority initialPriority = Priority.medium,
  Future<void> Function(String title, DateTime? deadline, Priority priority)?
  onSubmit,
}) async {
  // 🔒 Capture dependencies di awal — aman dari "context across async gaps"
  final prov = context.read<TodoProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  final titleCtrl = TextEditingController(text: initialTitle ?? '');
  DateTime? deadline = initialDeadline;
  Priority priority = initialPriority;

  // ✅ Deklarasikan submit() sebelum dipakai
  Future<void> submit() async {
    final text = titleCtrl.text.trim();
    if (text.isEmpty) return;

    if (onSubmit != null) {
      await onSubmit(text, deadline, priority);
    } else {
      await prov.add(title: text, deadline: deadline, priority: priority);
      messenger.showSnackBar(const SnackBar(content: Text('Task added')));
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: StatefulBuilder(
        builder: (ctx, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              initialTitle == null ? 'Add Task' : 'Edit Task',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            // Title
            TextField(
              controller: titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Task title'),
              onSubmitted: (_) async {
                await submit();
                if (!ctx.mounted) return;
                navigator.pop(); // pakai navigator yang sudah dicapture
              },
            ),

            const SizedBox(height: 12),

            // Deadline picker
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(
                      deadline == null ? 'Pick date' : _dateShort(deadline),
                    ),
                    onPressed: () async {
                      final pickedDate = await showDatePicker(
                        context: ctx,
                        initialDate: deadline ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (pickedDate == null) return;

                      final pickedTime = await showTimePicker(
                        // ignore: use_build_context_synchronously
                        context: ctx,
                        initialTime: TimeOfDay.fromDateTime(
                          deadline ?? DateTime.now(),
                        ),
                      );

                      // ✅ setelah async gap, pastikan masih mounted
                      if (!ctx.mounted) return;

                      setState(() {
                        deadline = DateTime(
                          pickedDate.year,
                          pickedDate.month,
                          pickedDate.day,
                          pickedTime?.hour ?? 9,
                          pickedTime?.minute ?? 0,
                        );
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                if (deadline != null)
                  IconButton(
                    tooltip: 'Clear deadline',
                    onPressed: () => setState(() => deadline = null),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),

            const SizedBox(height: 8),

            // Priority
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: Priority.values.map((p) {
                  return ChoiceChip(
                    selected: priority == p,
                    label: Text(_priorityText(p)),
                    onSelected: (_) => setState(() => priority = p),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 14),

            // Save
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Save'),
                onPressed: () async {
                  await submit();
                  // ❌ jangan pakai context setelah await; pakai navigator yang dicapture
                  navigator.pop();
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _dateShort(DateTime? dt) => dt == null
    ? '-'
    : '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}';

String _priorityTex(Priority p) {
  switch (p) {
    case Priority.high:
      return 'High';
    case Priority.medium:
      return 'Medium';
    case Priority.low:
      return 'Low';
  }
}
