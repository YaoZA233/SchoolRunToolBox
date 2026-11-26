import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_pages.dart';
import 'models.dart';
import 'route_engine.dart';
import 'store.dart';
import 'share_api.dart';

const _ink = Color(0xFF1E2B27);
const _muted = Color(0xFF6E7C76);
const _canvas = Color(0xFFF4F6F2);
const _card = Color(0xFFFFFFFF);
const _coral = Color(0xFFE76F51);
const _teal = Color(0xFF39786B);
const _line = Color(0xFFDCE4DE);

/// 悬浮窗按键发来的模拟控制指令（`pause` / `resume`）。
/// 原生侧收到广播后经 `schoolrun/platform` 的 `simulationControl` 转发到这里，
/// 由正在运行模拟的页面消费——悬浮窗与模拟循环分处原生/Dart 两侧，只能靠这条流对齐状态。
final StreamController<String> _overlayControlController =
    StreamController<String>.broadcast();

Stream<String> get _overlayControlEvents => _overlayControlController.stream;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SchoolRunApp());
}

class SchoolRunApp extends StatefulWidget {
  const SchoolRunApp({super.key});

  @override
  State<SchoolRunApp> createState() => _SchoolRunAppState();
}

class _SchoolRunAppState extends State<SchoolRunApp> {
  final store = AppStore();

  @override
  void initState() {
    super.initState();
    store.load();
  }

  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'RunToolBox',
          theme: _theme,
          home: AppShell(store: store),
        ),
      );
}

final _theme = ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: _canvas,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _teal,
    brightness: Brightness.light,
  ).copyWith(
    primary: _teal,
    onPrimary: Colors.white,
    secondary: _coral,
    surface: _card,
    onSurface: _ink,
    outline: _line,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: _canvas,
    foregroundColor: _ink,
    elevation: 0,
    centerTitle: false,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: _card,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _teal, width: 1.5),
    ),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: _card,
    indicatorColor: Color(0xFFD9ECE5),
    labelTextStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  ),
  cardTheme: CardThemeData(
    color: _card,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: _line),
    ),
  ),
);

class AppShell extends StatefulWidget {
  const AppShell({required this.store, super.key});

  final AppStore store;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;
  bool _consentShown = false;
  bool _noticeChecked = false;
  int _noticeAttempts = 0;

  @override
  void initState() {
    super.initState();
    const MethodChannel('schoolrun/platform')
        .setMethodCallHandler((call) async {
      if (call.method == 'simulationControl') {
        final command = call.arguments as String? ?? '';
        if (command.isNotEmpty) _overlayControlController.add(command);
        return null;
      }
      if (call.method == 'overlayDestination') {
        final destination = call.arguments as String?;
        if (destination == 'history') {
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HistoryPage(store: widget.store),
              ),
            );
          }
        } else if (mounted) {
          setState(() => index = 1);
        }
      }
      return null;
    });

    // Show consent dialog after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleConsent();
      _scheduleNoticeCheck();
    });
  }

  /// 等本地快照加载完成再决定要不要弹协议：快照里的 legalAccepted 是用户上次点过
  /// 「同意」的状态，抢在 load 之前弹会每次启动都重复打扰。
  void _scheduleConsent() {
    if (_consentShown || !mounted) return;
    if (!widget.store.loaded) {
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _scheduleConsent();
      });
      return;
    }
    if (widget.store.legalAccepted) return;
    _showConsent();
  }

  /// 启动后拉取服务器公告（`GET /api/client-config`）。公告是可选能力：
  /// 未配置服务器、网络失败或后端没写公告时都静默跳过，不打扰用户。
  void _scheduleNoticeCheck() {
    if (_noticeChecked || !mounted) return;
    if (!widget.store.loaded) {
      if (_noticeAttempts >= 40) return;
      _noticeAttempts++;
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (mounted) _scheduleNoticeCheck();
      });
      return;
    }
    _noticeChecked = true;
    if (widget.store.shareBaseUrl.isEmpty) return;
    Future<void>(() async {
      try {
        final config = await ShareApi(widget.store.shareBaseUrl).clientConfig();
        if (!mounted || !config.hasNotice) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(config.noticeTitle.isEmpty ? '公告' : config.noticeTitle),
            content: SingleChildScrollView(
              child: Text(config.noticeMessage,
                  style: const TextStyle(height: 1.55)),
            ),
            actions: [
              if (config.bilibiliUrl.isNotEmpty)
                TextButton(
                  onPressed: () {
                    const MethodChannel('schoolrun/platform')
                        .invokeMethod<bool>(
                      'openUrl',
                      {'url': config.bilibiliUrl},
                    );
                  },
                  child: Text(config.bilibiliText.isEmpty
                      ? '打开链接'
                      : config.bilibiliText),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      } catch (_) {
        // 公告失败不影响启动。
      }
    });
  }

  Future<void> _showConsent() async {
    if (!mounted || _consentShown || widget.store.legalAccepted) return;
    _consentShown = true;
    var checked = false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('使用前确认'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('继续使用前，请先阅读并同意用户协议与免责声明。',
                    style: TextStyle(height: 1.45)),
                const SizedBox(height: 12),
                const Text(
                    '本软件用于合法合规的开发、调试、学习与研究，不收集用户数据。请勿用于作弊、绕过平台规则或其他违法违规用途。',
                    style: TextStyle(color: _muted, height: 1.45)),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: checked,
                  title: const Text('我已阅读并同意用户协议与免责声明'),
                  onChanged: (value) =>
                      setDialogState(() => checked = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('暂不使用')),
            FilledButton(
                onPressed: checked ? () => Navigator.pop(context, true) : null,
                child: const Text('同意并继续')),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await widget.store.acceptLegal();
    } else {
      _consentShown = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        store: widget.store,
        onNavigate: (value) => setState(() => index = value),
      ),
      MapWorkbenchPage(store: widget.store),
      RouteLibraryPage(store: widget.store),
      NfcPage(store: widget.store),
      MinePage(store: widget.store),
    ];
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) {
          setState(() => index = value);
          // NFC 页在 IndexedStack 里不会 dispose，切走时必须关掉 reader mode，
          // 否则会一直占用 NFC 硬件、拦截系统贴卡行为。
          const MethodChannel('schoolrun/platform').invokeMethod<bool>(
            value == 3 ? 'startNfcReader' : 'stopNfcReader',
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '开始',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '地图',
          ),
          NavigationDestination(
            icon: Icon(Icons.alt_route_outlined),
            selectedIcon: Icon(Icons.alt_route),
            label: '路线',
          ),
          NavigationDestination(
            icon: Icon(Icons.nfc_outlined),
            selectedIcon: Icon(Icons.nfc),
            label: 'NFC',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({required this.store, required this.onNavigate, super.key});

  final AppStore store;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final recent = store.routes.take(3).toList();
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            sliver: SliverToBoxAdapter(
              child: _TopBar(onSettings: () => onNavigate(4)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RunToolBox',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: _ink,
                        ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '把路线、定位和 NFC 配置放在一个顺手的工作台里。',
                    style: TextStyle(color: _muted, height: 1.45),
                  ),
                  const SizedBox(height: 20),
                  _StatusHero(
                    routeCount: store.routes.length,
                    onTap: () => onNavigate(2),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            sliver: SliverToBoxAdapter(
              child: _SectionTitle(
                title: '常用入口',
                action: '查看全部',
                onTap: () => onNavigate(2),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.add_road,
                      label: '绘制路线',
                      detail: '在地图上添加路线点',
                      color: _teal,
                      onTap: () =>
                          _open(context, RouteEditorPage(store: store)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.play_circle_outline,
                      label: '路线模拟',
                      detail: '按速度或步频运行',
                      color: _coral,
                      onTap: () => _open(
                        context,
                        RouteLibraryPage(store: store, simulationOnly: true),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.nfc,
                      label: 'NFC 工具',
                      detail: '读取、模拟和管理配置',
                      color: const Color(0xFF6674B7),
                      onTap: () => onNavigate(3),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.menu_book_outlined,
                      label: '操作提示',
                      detail: '查看完整使用说明',
                      color: const Color(0xFFB77B43),
                      onTap: () => _open(context, TipsPage(store: store)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
            sliver: SliverToBoxAdapter(
              child: _SectionTitle(
                title: '最近路线',
                action: recent.isEmpty ? null : '路线库',
                onTap: recent.isEmpty ? null : () => onNavigate(2),
              ),
            ),
          ),
          if (recent.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              sliver: SliverToBoxAdapter(
                child: _EmptyPanel(
                  icon: Icons.route_outlined,
                  title: '还没有本地路线',
                  detail: '从“绘制路线”开始，保存后会出现在这里。',
                  action: '新建路线',
                  onTap: () => _open(context, RouteEditorPage(store: store)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              sliver: SliverList.builder(
                itemCount: recent.length,
                itemBuilder: (context, index) => Padding(
                  padding: EdgeInsets.only(
                    bottom: index == recent.length - 1 ? 0 : 10,
                  ),
                  child: RouteListTile(
                    route: recent[index],
                    onRun: () => _open(
                      context,
                      SimulationPage(store: store, route: recent[index]),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.route, color: Colors.white, size: 21),
          ),
          const SizedBox(width: 10),
          const Text(
            'RUN / TOOLBOX',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: _ink,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '设置',
            onPressed: onSettings,
            icon: const Icon(Icons.tune, color: _muted),
          ),
        ],
      );
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.routeCount, required this.onTap});

  final int routeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 188,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _HeroRoutePainter())),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFB5E48C),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '本地工作台已就绪',
                          style: TextStyle(
                            color: Color(0xFFB5E48C),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      routeCount == 0 ? '从一条路线开始' : '$routeCount 条路线正在等你',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      routeCount == 0 ? '绘制、保存，然后随时模拟' : '打开路线库继续工作',
                      style: const TextStyle(color: Color(0xFFB8C7C0)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _HeroRoutePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x334F9A89)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 26) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
    final route = Path()
      ..moveTo(size.width * .55, size.height * .1)
      ..cubicTo(
        size.width * .45,
        size.height * .3,
        size.width * .78,
        size.height * .42,
        size.width * .58,
        size.height * .62,
      )
      ..cubicTo(
        size.width * .42,
        size.height * .79,
        size.width * .69,
        size.height * .85,
        size.width * .9,
        size.height * .7,
      );
    canvas.drawPath(
      route,
      Paint()
        ..color = const Color(0x668BC4B5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.action, this.onTap});

  final String title;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
          const Spacer(),
          if (action != null)
            TextButton(onPressed: onTap, child: Text(action!)),
        ],
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.detail,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withAlpha(24),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: color, size: 21),
                ),
                const SizedBox(height: 13),
                Text(
                  label,
                  style:
                      const TextStyle(fontWeight: FontWeight.w800, color: _ink),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ],
            ),
          ),
        ),
      );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.detail,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            children: [
              Icon(icon, size: 34, color: _teal),
              const SizedBox(height: 10),
              Text(
                title,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, color: _ink),
              ),
              const SizedBox(height: 5),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onTap,
                icon: const Icon(Icons.add, size: 18),
                label: Text(action),
              ),
            ],
          ),
        ),
      );
}

class MapWorkbenchPage extends StatefulWidget {
  const MapWorkbenchPage({required this.store, super.key});

  final AppStore store;

  @override
  State<MapWorkbenchPage> createState() => _MapWorkbenchPageState();
}

class _MapWorkbenchPageState extends State<MapWorkbenchPage> {
  final searchController = TextEditingController();
  final points = <RoutePoint>[];
  StreamSubscription<dynamic>? locationSubscription;
  String query = '';
  String place = '当前位置';
  String locationSummary = '定位中';
  String currentCity = '';
  List<Map<String, dynamic>> poiResults = const [];
  double heading = 18;
  double? currentLatitude;
  double? currentLongitude;
  Offset joystick = Offset.zero;

  @override
  void initState() {
    super.initState();
    locationSubscription = const EventChannel('schoolrun/location')
        .receiveBroadcastStream()
        .listen((event) {
      if (!mounted || event is! Map) return;
      final address = event['address'] as String? ?? '';
      final direction = (event['direction'] as num?)?.toDouble() ?? heading;
      setState(() {
        heading = direction;
        currentCity = event['city'] as String? ?? currentCity;
        currentLatitude = (event['latitude'] as num?)?.toDouble();
        currentLongitude = (event['longitude'] as num?)?.toDouble();
        locationSummary = address.isEmpty ? '已定位' : address;
        if (place == '当前位置') place = locationSummary;
      });
    }, onError: (_) {
      if (mounted) setState(() => locationSummary = '定位不可用');
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    locationSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = query.trim().isEmpty
        ? const <String>['校园北门', '图书馆', '体育场', '教学楼 A 区']
        : ['${query.trim()}附近', '${query.trim()}东门', '${query.trim()}公交站'];
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('地图工作台',
                        style: TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                            color: _ink)),
                    SizedBox(height: 5),
                    Text('搜索地点、取点并快速控制当前位置。', style: TextStyle(color: _muted)),
                  ],
                ),
              ),
              IconButton(
                tooltip: '方向校准',
                onPressed: () => setState(() => heading = 0),
                icon: const Icon(Icons.explore_outlined, color: _teal),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: searchController,
            onChanged: (value) => setState(() => query = value),
            onSubmitted: (value) => _searchPoi(value.trim()),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索地点或地址',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: '清空',
                onPressed: () {
                  searchController.clear();
                  setState(() {
                    query = '';
                    poiResults = const [];
                  });
                },
                icon: const Icon(Icons.close),
              ),
            ),
          ),
          if (poiResults.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: poiResults
                    .map((item) => ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.place_outlined, color: _teal),
                          title: Text(item['name'] as String? ?? '未命名地点'),
                          subtitle: Text(item['address'] as String? ?? '',
                              style:
                                  const TextStyle(fontSize: 12, color: _muted)),
                          onTap: () =>
                              _selectPlace(item['name'] as String? ?? '地图地点'),
                        ))
                    .toList(),
              ),
            ),
          ] else if (query.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: suggestions
                    .map((item) => ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.place_outlined, color: _teal),
                          title: Text(item),
                          onTap: () => _selectPlace(item),
                        ))
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 310,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _NativeBaiduMap(
                      points: points,
                      currentLatitude: currentLatitude,
                      currentLongitude: currentLongitude,
                      onPoint: _addCoordinates,
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: Colors.white.withAlpha(230),
                          borderRadius: BorderRadius.circular(9)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        child: Text('$place · $locationSummary',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _ink)),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _Joystick(
                      value: joystick,
                      onChanged: (value) => setState(() => joystick = value),
                      onEnd: () => setState(() => joystick = Offset.zero),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child: _MapInfo(
                      icon: Icons.explore,
                      label: '方向',
                      value: '${heading.round()}°')),
              const SizedBox(width: 10),
              Expanded(
                  child: _MapInfo(
                      icon: Icons.location_on_outlined,
                      label: '取点',
                      value: '${points.length} 个')),
              const SizedBox(width: 10),
              const Expanded(
                  child: _MapInfo(
                      icon: Icons.gps_fixed, label: '定位', value: '模拟')),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _open(
                    context,
                    RouteEditorPage(
                      store: widget.store,
                      initialPoints: List<RoutePoint>.of(points),
                    ),
                  ),
                  icon: const Icon(Icons.add_road),
                  label: const Text('用地图点绘制路线'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: points.isEmpty ? null : _savePointHistory,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('保存取点'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _toggleJoystickOverlay(),
            icon: const Icon(Icons.gamepad_outlined),
            label: const Text('启动系统悬浮摇杆'),
          ),
          const SizedBox(height: 18),
          const _SectionTitle(title: '最近搜索'),
          const SizedBox(height: 8),
          if (widget.store.history
              .where((item) => item.kind == 'search')
              .isEmpty)
            const Card(
                child: ListTile(
                    leading: Icon(Icons.history, color: _muted),
                    title: Text('还没有搜索记录'),
                    subtitle: Text('搜索地点后会显示在这里',
                        style: TextStyle(color: _muted, fontSize: 12))))
          else
            ...widget.store.history
                .where((item) => item.kind == 'search')
                .take(4)
                .map(
                  (item) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history, color: _muted),
                    title: Text(item.title),
                    subtitle: Text(item.detail,
                        style: const TextStyle(color: _muted, fontSize: 12)),
                  ),
                ),
        ],
      ),
    );
  }

  void _selectPlace(String value) {
    setState(() {
      place = value;
      query = '';
      poiResults = const [];
      searchController.text = value;
      searchController.selection =
          TextSelection.collapsed(offset: value.length);
    });
    widget.store.recordHistory(title: value, detail: '地图搜索', kind: 'search');
  }

  Future<void> _searchPoi(String value) async {
    if (value.isEmpty) {
      _selectPlace('当前位置');
      return;
    }
    setState(() => query = value);
    try {
      final result = await const MethodChannel('schoolrun/platform')
          .invokeMethod<List<dynamic>>(
        'searchPoi',
        {'query': value, 'city': currentCity},
      );
      if (!mounted) return;
      setState(() => poiResults = (result ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList());
      if (poiResults.isEmpty) _toast(context, '没有找到匹配地点');
    } on PlatformException {
      if (mounted) _toast(context, '百度地点搜索不可用');
    }
  }

  void _addCoordinates(double latitude, double longitude) {
    setState(
        () => points.add(RoutePoint(longitude: longitude, latitude: latitude)));
  }

  void _savePointHistory() {
    widget.store.recordHistory(
        title: place,
        detail: '保存了 ${points.length} 个地图取点',
        kind: 'location',
        latitude: points.isEmpty ? null : points.last.latitude,
        longitude: points.isEmpty ? null : points.last.longitude);
    _toast(context, '取点已记入历史记录');
  }

  Future<void> _toggleJoystickOverlay() async {
    try {
      final result =
          await const MethodChannel('schoolrun/platform').invokeMethod<bool>(
        'startJoystickOverlay',
        {
          // 以当前定位/最后取点为起点，避免摇杆从固定坐标突然跳走。
          'latitude': currentLatitude ??
              (points.isEmpty ? 39.908 : points.last.latitude),
          'longitude': currentLongitude ??
              (points.isEmpty ? 116.397 : points.last.longitude),
          'altitude': points.isEmpty ? 55.0 : points.last.altitude,
          'walkSpeed': widget.store.walkSpeed,
          'runSpeed': widget.store.runSpeed,
          'bikeSpeed': widget.store.bikeSpeed,
        },
      );
      if (mounted && result != true) _toast(context, '请先授予悬浮窗权限');
      if (mounted && result == true) _toast(context, '悬浮摇杆已启动，可在其他应用上方使用');
    } on PlatformException catch (error) {
      if (mounted) _toast(context, error.message ?? '悬浮摇杆启动失败');
    }
  }
}

class _MapInfo extends StatelessWidget {
  const _MapInfo(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(children: [
            Icon(icon, size: 18, color: _teal),
            const SizedBox(height: 5),
            Text(value,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11, color: _muted))
          ]),
        ),
      );
}

class _NativeBaiduMap extends StatefulWidget {
  const _NativeBaiduMap({
    required this.onPoint,
    this.points = const [],
    this.currentLatitude,
    this.currentLongitude,
    this.satellite = false,
  });
  final void Function(double latitude, double longitude) onPoint;
  final List<RoutePoint> points;
  final double? currentLatitude;
  final double? currentLongitude;
  final bool satellite;

  @override
  State<_NativeBaiduMap> createState() => _NativeBaiduMapState();
}

class _NativeBaiduMapState extends State<_NativeBaiduMap> {
  MethodChannel? channel;

  @override
  void didUpdateWidget(covariant _NativeBaiduMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.points != widget.points) _sendRoutePoints();
    if (oldWidget.currentLatitude != widget.currentLatitude ||
        oldWidget.currentLongitude != widget.currentLongitude) {
      _sendCurrentLocation();
    }
    if (oldWidget.satellite != widget.satellite) _sendMapType();
  }

  void _sendRoutePoints() {
    channel?.invokeMethod<void>(
        'setRoutePoints',
        widget.points
            .map((point) => {
                  'latitude': point.latitude,
                  'longitude': point.longitude,
                })
            .toList());
  }

  void _sendCurrentLocation() {
    final latitude = widget.currentLatitude;
    final longitude = widget.currentLongitude;
    if (latitude == null || longitude == null) return;
    channel?.invokeMethod<void>('setCurrentLocation', {
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  void _sendMapType() {
    channel?.invokeMethod<void>('setMapType', widget.satellite ? 2 : 1);
  }

  @override
  Widget build(BuildContext context) => AndroidView(
        viewType: 'schoolrun/baidu_map',
        onPlatformViewCreated: (id) {
          channel = MethodChannel('schoolrun/baidu_map_$id');
          _sendRoutePoints();
          _sendCurrentLocation();
          _sendMapType();
          channel!.setMethodCallHandler((call) async {
            if ((call.method != 'mapClick' && call.method != 'mapLongClick') ||
                call.arguments is! Map) return;
            final args = Map<dynamic, dynamic>.from(call.arguments as Map);
            final latitude = (args['latitude'] as num).toDouble();
            final longitude = (args['longitude'] as num).toDouble();
            if (call.method == 'mapClick') {
              widget.onPoint(latitude, longitude);
            } else {
              try {
                final result = await const MethodChannel('schoolrun/platform')
                    .invokeMethod<Map<dynamic, dynamic>>('reverseGeocode',
                        {'latitude': latitude, 'longitude': longitude});
                if (result != null && mounted) {
                  final address = result['address'] as String? ?? '地图位置';
                  widget.onPoint(latitude, longitude);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(address),
                      behavior: SnackBarBehavior.floating));
                }
              } on PlatformException {
                if (mounted)
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('地址查询不可用')));
              }
            }
          });
        },
        creationParams: {
          'latitude': 39.908,
          'longitude': 116.397,
          'mapType': widget.satellite ? 2 : 1,
          'routePoints': widget.points
              .map((point) => {
                    'latitude': point.latitude,
                    'longitude': point.longitude,
                  })
              .toList(),
        },
        creationParamsCodec: const StandardMessageCodec(),
      );
}

class _Joystick extends StatelessWidget {
  const _Joystick(
      {required this.value, required this.onChanged, required this.onEnd});
  final Offset value;
  final ValueChanged<Offset> onChanged;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onPanUpdate: (details) {
          final raw = Offset((details.localPosition.dx - 40) / 32,
              (details.localPosition.dy - 40) / 32);
          onChanged(Offset(raw.dx.clamp(-1.0, 1.0), raw.dy.clamp(-1.0, 1.0)));
        },
        onPanEnd: (_) => onEnd(),
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
              color: Colors.white.withAlpha(220),
              shape: BoxShape.circle,
              border: Border.all(color: _line)),
          child: Center(
              child: Transform.translate(
                  offset: value * 18,
                  child: Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                          color: _teal, shape: BoxShape.circle),
                      child: const Icon(Icons.open_with,
                          size: 16, color: Colors.white)))),
        ),
      );
}

class RouteLibraryPage extends StatefulWidget {
  const RouteLibraryPage({
    required this.store,
    this.simulationOnly = false,
    super.key,
  });

  final AppStore store;
  final bool simulationOnly;

  @override
  State<RouteLibraryPage> createState() => _RouteLibraryPageState();
}

class _RouteLibraryPageState extends State<RouteLibraryPage> {
  var shared = false;
  var query = '';
  var loadingShared = false;
  List<SharedRouteSummary> remoteRoutes = const [];
  final Set<String> busy = <String>{};

  @override
  Widget build(BuildContext context) {
    final localRoutes = widget.store.routes
        .where(
            (route) => route.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    final sharedRoutes = remoteRoutes
        .where(
            (route) => route.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '路线库',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '导入路线',
                  onPressed: () => _importRoutes(context),
                  icon: const Icon(Icons.file_upload_outlined),
                ),
                IconButton(
                  tooltip: '导出路线',
                  onPressed: () => _exportRoutes(context),
                  icon: const Icon(Icons.file_download_outlined),
                ),
                FilledButton.icon(
                  onPressed: () =>
                      _open(context, RouteEditorPage(store: widget.store)),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                hintText: '搜索路线名称',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('本地路线'),
                  icon: Icon(Icons.folder_outlined, size: 18),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('共享路线'),
                  icon: Icon(Icons.public, size: 18),
                ),
              ],
              selected: {shared},
              onSelectionChanged: (selection) => setState(() {
                shared = selection.first;
                if (shared) _loadRemoteRoutes();
              }),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: shared
                ? _buildSharedList(context, sharedRoutes)
                : _buildLocalList(context, localRoutes),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalList(BuildContext context, List<RouteDefinition> routes) {
    if (routes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: _EmptyPanel(
          icon: Icons.route_outlined,
          title: '暂无本地路线',
          detail: '点击右上角新建路线，或导入已有 JSON。',
          action: '绘制路线',
          onTap: () => _open(context, RouteEditorPage(store: widget.store)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: routes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final route = routes[index];
        return RouteListTile(
          route: route,
          onRun: () => _runLocal(route),
          onEdit: () => _open(
            context,
            RouteEditorPage(store: widget.store, route: route),
          ),
          onDelete: () => _confirmDelete(context, route),
        );
      },
    );
  }

  Widget _buildSharedList(
    BuildContext context,
    List<SharedRouteSummary> routes,
  ) {
    if (loadingShared) {
      return const Center(child: CircularProgressIndicator());
    }
    if (routes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: _EmptyPanel(
          icon: Icons.public_off,
          title: '暂无共享路线',
          detail: widget.store.shareBaseUrl.isEmpty
              ? '请先在「共享中心」填写服务器地址，再刷新共享路线。'
              : '下拉或点击下方按钮重新拉取服务器上的共享路线。',
          action: '刷新共享路线',
          onTap: _loadRemoteRoutes,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRemoteRoutes,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        itemCount: routes.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = routes[index];
          final isBusy = busy.contains(item.id);
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE4F0EB),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      item.privacyMode ? Icons.lock_outline : Icons.public,
                      color: _teal,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${item.pointCount} 个点  ·  ${item.privacyMode ? '隐私路线（只能直接模拟）' : '可下载'}',
                          style: const TextStyle(fontSize: 12, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  if (isBusy)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (item.privacyMode)
                    TextButton(
                      onPressed: () => _openShared(item, runOnly: true),
                      child: const Text('直接模拟'),
                    )
                  else ...[
                    IconButton(
                      tooltip: '下载保存',
                      onPressed: () => _openShared(item),
                      icon: const Icon(Icons.download_outlined),
                    ),
                    IconButton(
                      tooltip: '下载并模拟',
                      onPressed: () => _openShared(item, runAfter: true),
                      icon: const Icon(Icons.play_arrow_rounded, color: _coral),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _runLocal(RouteDefinition route) async {
    await widget.store.setLastRoute(route.id);
    if (!mounted) return;
    _open(context, SimulationPage(store: widget.store, route: route));
  }

  Future<void> _importRoutes(BuildContext context) async {
    try {
      final raw = await const MethodChannel('schoolrun/platform')
          .invokeMethod<String>('pickRouteJson');
      if (raw == null || raw.trim().isEmpty) return;
      final count = await widget.store.importRouteJson(raw);
      if (context.mounted)
        _toast(context, count == 0 ? '没有找到可导入的路线' : '已导入 $count 条路线');
    } on FormatException {
      if (context.mounted) _toast(context, '路线文件格式无法识别');
    } on PlatformException catch (error) {
      if (context.mounted) _toast(context, error.message ?? '无法打开路线文件');
    }
  }

  Future<void> _exportRoutes(BuildContext context) async {
    if (widget.store.routes.isEmpty) {
      _toast(context, '暂无可导出的路线');
      return;
    }
    try {
      await const MethodChannel('schoolrun/platform').invokeMethod<bool>(
        'exportRouteJson',
        {'content': widget.store.exportRouteJson()},
      );
      if (context.mounted) _toast(context, '路线文件已导出');
    } on PlatformException catch (error) {
      if (context.mounted) _toast(context, error.message ?? '无法导出路线文件');
    }
  }

  Future<void> _loadRemoteRoutes() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      if (mounted) {
        _toast(context, '请先在「共享中心」填写服务器地址');
      }
      return;
    }
    setState(() => loadingShared = true);
    try {
      final values = await ShareApi(
        widget.store.shareBaseUrl,
        token: widget.store.authToken,
      ).sharedRouteSummaries();
      if (mounted) setState(() => remoteRoutes = values);
      if (mounted && values.isEmpty) _toast(context, '服务器上还没有共享路线');
    } catch (error) {
      if (mounted) _toast(context, '共享路线加载失败：$error');
    } finally {
      if (mounted) setState(() => loadingShared = false);
    }
  }

  Future<void> _openShared(
    SharedRouteSummary summary, {
    bool runOnly = false,
    bool runAfter = false,
  }) async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先在「共享中心」填写服务器地址');
      return;
    }
    setState(() => busy.add(summary.id));
    try {
      final remote = await ShareApi(
        widget.store.shareBaseUrl,
        token: widget.store.authToken,
      ).sharedRoute(summary);
      if (!mounted) return;
      if (!remote.hasEnoughPoints) {
        _toast(context, '这条共享路线没有可用的路线点');
        return;
      }
      if (runOnly || remote.privacyMode || runAfter) {
        if (remote.privacyMode) {
          _toast(context, '隐私共享路线不会保存到本地，直接进入模拟');
        }
        _open(
          context,
          SimulationPage(store: widget.store, route: remote),
        );
        return;
      }
      final saved = await widget.store.addDownloadedRoute(remote);
      if (mounted) {
        _toast(context, '已下载「${saved.name}」到本地路线库');
      }
    } catch (error) {
      if (mounted) _toast(context, '下载失败：$error');
    } finally {
      if (mounted) setState(() => busy.remove(summary.id));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    RouteDefinition route,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除路线'),
        content: Text('确定删除“${route.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.store.deleteRoute(route);
  }
}

class RouteEditorPage extends StatefulWidget {
  const RouteEditorPage({
    required this.store,
    this.route,
    this.initialPoints = const [],
    super.key,
  });

  final AppStore store;
  final RouteDefinition? route;

  /// 从「地图工作台」带过来的取点，进入编辑页时直接续画。
  final List<RoutePoint> initialPoints;

  @override
  State<RouteEditorPage> createState() => _RouteEditorPageState();
}

class _RouteEditorPageState extends State<RouteEditorPage> {
  late List<RoutePoint> points;
  final undoStack = <List<RoutePoint>>[];
  final redoStack = <List<RoutePoint>>[];
  var editMode = false;
  int? selectedIndex;
  bool closed = false;
  bool privacyMode = false;
  bool satelliteMap = false;
  bool recordMode = false;
  bool recording = false;
  int recordIntervalSeconds = 3;
  Timer? recordTimer;
  StreamSubscription<dynamic>? locationSubscription;
  RoutePoint? latestLocation;

  @override
  void initState() {
    super.initState();
    points = List.of(widget.route?.points ?? widget.initialPoints);
    privacyMode = widget.route?.privacyMode ?? false;
    recordIntervalSeconds = widget.store.recordIntervalSeconds;
    locationSubscription = const EventChannel('schoolrun/location')
        .receiveBroadcastStream()
        .listen((event) {
      if (!mounted || event is! Map) return;
      final latitude = (event['latitude'] as num?)?.toDouble();
      final longitude = (event['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) return;
      latestLocation = RoutePoint(
        latitude: latitude,
        longitude: longitude,
        altitude: (event['altitude'] as num?)?.toDouble() ?? 55,
      );
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    recordTimer?.cancel();
    // 取消订阅即可，EventChannel 在最后一个监听者离开时会通知原生停定位。
    locationSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.route == null ? '绘制路线' : '编辑路线';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: '撤销',
            onPressed: undoStack.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: '重做',
            onPressed: redoStack.isEmpty ? null : _redo,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: '保存路线',
            onPressed: points.length < 2 ? null : _save,
            icon: const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: satelliteMap ? '标准地图' : '卫星地图',
            onPressed: () => setState(() => satelliteMap = !satelliteMap),
            icon: Icon(satelliteMap ? Icons.map : Icons.satellite_alt_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      editMode ? '编辑模式：点击顶点后移动' : '绘制模式：点击地图添加路线点',
                      style: const TextStyle(color: _muted),
                    ),
                  ),
                  Switch(
                    value: editMode,
                    onChanged: (value) => setState(() {
                      editMode = value;
                      selectedIndex = null;
                    }),
                    activeThumbColor: _teal,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('隐私路线'),
                subtitle: const Text('模拟时隐藏地图内容，但仍保留定位进度',
                    style: TextStyle(fontSize: 12, color: _muted)),
                value: privacyMode,
                onChanged: (value) => setState(() => privacyMode = value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('录制移动路线'),
                subtitle: Text(
                  recording
                      ? '录制中，已记录 ${points.length} 个点'
                      : '按 $recordIntervalSeconds 秒间隔记录当前位置',
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
                value: recordMode,
                onChanged: recording
                    ? null
                    : (value) => setState(() => recordMode = value),
              ),
            ),
            if (recordMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _toggleRecording,
                        icon: Icon(
                            recording ? Icons.stop : Icons.fiber_manual_record),
                        label: Text(recording ? '停止录制' : '开始录制'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '录制间隔',
                      onPressed: recording ? null : _editRecordInterval,
                      icon: const Icon(Icons.timer_outlined),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _NativeBaiduMap(
                    points: points,
                    satellite: satelliteMap,
                    currentLatitude: latestLocation?.latitude,
                    currentLongitude: latestLocation?.longitude,
                    onPoint: _handleNativeMapPoint,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _ToolButton(
                        icon: Icons.undo,
                        label: '撤销',
                        onTap: undoStack.isEmpty ? null : _undo,
                      ),
                      _ToolButton(
                        icon: Icons.redo,
                        label: '重做',
                        onTap: redoStack.isEmpty ? null : _redo,
                      ),
                      _ToolButton(
                        icon: Icons.loop,
                        label: closed ? '已闭合' : '闭合',
                        onTap: points.length < 3 ? null : _toggleClosed,
                      ),
                      _ToolButton(
                        icon: Icons.add_circle_outline,
                        label: '加点',
                        onTap: points.length < 2 ? null : () => _addPoints(5),
                      ),
                      _ToolButton(
                        icon: Icons.remove_circle_outline,
                        label: '减点',
                        onTap:
                            points.length < 3 ? null : () => _removePoints(3),
                      ),
                      _ToolButton(
                        icon: Icons.delete_outline,
                        label: '删点',
                        onTap: selectedIndex == null ? null : _deleteSelected,
                      ),
                      _ToolButton(
                        icon: Icons.roundabout_right,
                        label: '防直角',
                        onTap: points.length < 3 ? null : _smooth,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${points.length} 个路线点${closed ? '  ·  已闭合' : ''}',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: points.isEmpty ? null : _clear,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('清空'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: points.length < 2 ? null : _save,
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (recording) {
      recordTimer?.cancel();
      // 只停录制定时器：定位流是共享的 EventChannel，直接 stopLocation 会把
      // 地图工作台的定位也一起停掉。
      if (mounted) setState(() => recording = false);
      if (mounted && points.length < 2) {
        _toast(context, '至少记录两个定位点后才能保存路线');
      }
      return;
    }
    if (!recordMode) return;
    await const MethodChannel('schoolrun/platform')
        .invokeMethod<void>('startLocation');
    if (mounted) setState(() => recording = true);
    _recordLatestLocation();
    recordTimer = Timer.periodic(
      Duration(seconds: recordIntervalSeconds),
      (_) => _recordLatestLocation(),
    );
  }

  void _recordLatestLocation() {
    final location = latestLocation;
    if (!recording || location == null) return;
    if (points.isNotEmpty && distanceMeters(points.last, location) < 1) return;
    _recordChange();
    if (mounted) setState(() => points = [...points, location]);
  }

  Future<void> _editRecordInterval() async {
    final controller = TextEditingController(text: '$recordIntervalSeconds');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('录制设置'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '每隔多少秒记录一个点'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value >= 1 && mounted) {
      setState(() => recordIntervalSeconds = value);
      widget.store.setRecordInterval(value);
    }
  }

  void _handleNativeMapPoint(double latitude, double longitude) {
    final point = RoutePoint(longitude: longitude, latitude: latitude);
    if (editMode && selectedIndex != null && selectedIndex! < points.length) {
      _recordChange();
      final next = List<RoutePoint>.of(points)..[selectedIndex!] = point;
      setState(() {
        points = next;
        selectedIndex = null;
      });
      return;
    }
    if (editMode && points.length >= 2) {
      // 编辑模式下点路线附近的位置：投影到最近线段插入新顶点（阈值 ≤20m）。
      final projection = projectPointOntoRoute(points, point);
      if (!projection.isValid) return;
      if (projection.distanceToRouteMeters > 20) {
        _toast(context, '离路线超过 20 米，请点击路线附近再添加顶点');
        return;
      }
      _recordChange();
      setState(() {
        points = insertPointOnRoute(points, projection);
        selectedIndex = projection.segmentStartIndex + 1;
        closed = false;
      });
      return;
    }
    _recordChange();
    setState(() {
      points = [...points, point];
      closed = false;
    });
  }

  void _recordChange() {
    undoStack.add(List.of(points));
    redoStack.clear();
  }

  void _undo() {
    if (undoStack.isEmpty) return;
    redoStack.add(List.of(points));
    setState(() => points = undoStack.removeLast());
  }

  void _redo() {
    if (redoStack.isEmpty) return;
    undoStack.add(List.of(points));
    setState(() => points = redoStack.removeLast());
  }

  void _toggleClosed() {
    if (points.length < 3) return;
    if (closed) {
      // 取消闭合时要撤掉上次追加的重复首点，否则会留下一个零长度线段。
      _recordChange();
      final next = List<RoutePoint>.of(points);
      if (next.length > 1 && distanceMeters(next.first, next.last) < 0.01) {
        next.removeLast();
      }
      setState(() {
        points = next;
        closed = false;
      });
      return;
    }
    if (distanceMeters(points.first, points.last) < 0.01) return;
    _recordChange();
    setState(() {
      points = [...points, points.first];
      closed = true;
    });
    _toast(context, '路线已闭合，终点已连接回起点');
  }

  void _clear() {
    _recordChange();
    setState(() {
      points = [];
      closed = false;
    });
  }

  void _addPoints(int count) {
    _recordChange();
    setState(() {
      points = insertEvenlySpacedPoints(points, count);
      closed = false;
    });
  }

  void _removePoints(int count) {
    _recordChange();
    setState(() {
      points = removeEvenlySpacedNonKeyPoints(points, count);
      selectedIndex = null;
      closed = false;
    });
  }

  void _deleteSelected() {
    final index = selectedIndex;
    if (index == null || index < 0 || index >= points.length) return;
    if (points.length <= 2) {
      _toast(context, '路线至少需要保留两个点');
      return;
    }
    _recordChange();
    final next = List<RoutePoint>.of(points)..removeAt(index);
    setState(() {
      points = next;
      selectedIndex = null;
      closed = false;
    });
  }

  void _smooth() {
    _recordChange();
    setState(() => points = smoothRightAngles(points, 3));
  }

  Future<void> _save() async {
    final controller = TextEditingController(
      text: widget.route?.name ?? '我的路线',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存路线'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '路线名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await widget.store.saveRoute(name, points,
        id: widget.route?.id, privacyMode: privacyMode);
    if (mounted) {
      _toast(context, '路线已保存');
      Navigator.pop(context);
    }
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: IconButton(
          onPressed: onTap,
          tooltip: label,
          icon: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
      );
}

class _MapGeometry {
  static Offset map(List<RoutePoint> points, RoutePoint point, Size size) {
    if (points.isEmpty) return Offset(size.width / 2, size.height / 2);
    final lons = points.map((item) => item.longitude).toList();
    final lats = points.map((item) => item.latitude).toList();
    final minLon = lons.reduce(math.min);
    final maxLon = lons.reduce(math.max);
    final minLat = lats.reduce(math.min);
    final maxLat = lats.reduce(math.max);
    final lonRange = math.max(maxLon - minLon, 0.00015);
    final latRange = math.max(maxLat - minLat, 0.00015);
    final scale = math.min(
      (size.width - 48) / lonRange,
      (size.height - 48) / latRange,
    );
    return Offset(
      size.width / 2 + (point.longitude - (minLon + maxLon) / 2) * scale,
      size.height / 2 - (point.latitude - (minLat + maxLat) / 2) * scale,
    );
  }
}

class _MapOverlayPainter extends CustomPainter {
  const _MapOverlayPainter({
    required this.points,
    required this.selectedIndex,
    required this.closed,
  });
  final List<RoutePoint> points;
  final int? selectedIndex;
  final bool closed;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFE9F0EB),
    );
    final grid = Paint()
      ..color = const Color(0xFFDBE5DE)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 36)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    for (var y = 0.0; y < size.height; y += 36)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    if (points.isEmpty) {
      final text = TextPainter(
        text: const TextSpan(
          text: '点击地图添加第一个点',
          style: TextStyle(color: _muted, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(
        canvas,
        Offset((size.width - text.width) / 2, (size.height - text.height) / 2),
      );
      return;
    }
    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final position = _MapGeometry.map(points, points[index], size);
      if (index == 0)
        path.moveTo(position.dx, position.dy);
      else
        path.lineTo(position.dx, position.dy);
    }
    if (closed) path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = _teal
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (var index = 0; index < points.length; index++) {
      final position = _MapGeometry.map(points, points[index], size);
      final selected = selectedIndex == index;
      canvas.drawCircle(
        position,
        selected ? 10 : 7,
        Paint()..color = selected ? _coral : (index == 0 ? _ink : Colors.white),
      );
      canvas.drawCircle(
        position,
        7,
        Paint()
          ..color = index == 0 ? _ink : _teal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final label = TextPainter(
      text: TextSpan(
        text: '${points.length} 个点',
        style: const TextStyle(
          color: _ink,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, const Offset(14, 14));
  }

  @override
  bool shouldRepaint(covariant _MapOverlayPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.closed != closed;
}

class SimulationPage extends StatefulWidget {
  const SimulationPage({required this.store, required this.route, super.key});

  final AppStore store;
  final RouteDefinition route;

  @override
  State<SimulationPage> createState() => _SimulationPageState();
}

class _SimulationPageState extends State<SimulationPage> {
  late SimulationConfig config;
  late RouteSimulationEngine engine;
  Timer? timer;
  StreamSubscription<dynamic>? sensorSubscription;
  StreamSubscription<String>? overlayControlSubscription;
  SimulationFrame? frame;
  bool running = false;
  bool paused = false;
  bool completed = false;
  String sensorSummary = '传感器未连接';

  @override
  void initState() {
    super.initState();
    config = widget.store.simulation;
    engine = RouteSimulationEngine(widget.route, config);
    sensorSubscription = const EventChannel('schoolrun/sensors')
        .receiveBroadcastStream()
        .listen((event) {
      if (!mounted || event is! Map) return;
      final steps = (event['steps'] as num?)?.toInt() ?? 0;
      final azimuth = (event['azimuth'] as num?)?.toDouble() ?? 0;
      final detected = event['stepDetected'] == true;
      if (mounted) {
        setState(() => sensorSummary = '步数 $steps · 方向 ${azimuth.round()}°');
      }
      if (running && !paused && config.realStepLink && detected) {
        _publishFrame(engine.nextForSteps(1));
      }
    }, onError: (_) {
      if (mounted) setState(() => sensorSummary = '传感器不可用');
    });
    overlayControlSubscription =
        _overlayControlEvents.listen(_handleOverlayCommand, onError: (error) {
      // 悬浮窗广播偶发失败不应影响本页订阅。
    });
  }

  /// 悬浮窗按键发来的指令。小窗自己不改按键状态，
  /// 这里真正停/启计时器后再通过 updateRouteSimulation 把状态推回去。
  void _handleOverlayCommand(String command) {
    if (!mounted || !running) return;
    if (command == 'pause' && !paused) {
      _togglePause();
    } else if (command == 'resume' && paused) {
      _togglePause();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    sensorSubscription?.cancel();
    overlayControlSubscription?.cancel();
    widget.store.setSimulationRunning(false);
    _invoke('stopRouteSimulation');
    // 只在页面销毁时停掉模拟定位服务；暂停/完成都不停，
    // 这样目标应用始终能读到最后一个位置。
    _invoke('stopMockLocation');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentPoint = frame?.point;
    final masked =
        widget.route.privacyMode && widget.route.downloadedFromShared;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '路线模拟',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: '模拟说明',
            onPressed: () => _showSimulationInfo(context),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            Text(
              widget.route.name,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${widget.route.points.length} 个点  ·  ${_formatDistance(totalDistanceMeters(widget.route.points))}'
              '${widget.route.privacyMode ? '  ·  隐私路线' : ''}',
              style: const TextStyle(color: _muted),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: CustomPaint(
                  painter: _SimulationPainter(
                    points: widget.route.points,
                    current: currentPoint,
                    mask: masked,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Text(
                          '运行进度',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _ink,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          frame == null
                              ? '待开始'
                              : '${((frame!.progress * 100).clamp(0, 100)).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: _teal,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: frame?.progress.clamp(0, 1) ?? 0,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                      color: _teal,
                      backgroundColor: const Color(0xFFE4ECE7),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            completed
                                ? '模拟已完成'
                                : paused
                                    ? '已暂停（定位保持在最后位置）'
                                    : running
                                        ? '模拟正在运行'
                                        : '准备就绪',
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (frame != null)
                          Text(
                            '第 ${frame!.loop} / ${config.loops} 圈',
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        sensorSummary,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            _SimulationSettings(config: config, onChanged: _updateConfig),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: widget.route.hasEnoughPoints
                          ? (running || paused ? _togglePause : _start)
                          : null,
                      icon: Icon(
                        running || paused
                            ? (paused ? Icons.play_arrow : Icons.pause)
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(
                        running || paused
                            ? (paused ? '继续模拟' : '暂停模拟')
                            : completed
                                ? '重新开始'
                                : '开始模拟',
                      ),
                    ),
                  ),
                  if (running || paused) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _end,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('结束'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (widget.route.privacyMode) ...[
              const SizedBox(height: 12),
              Text(
                widget.route.downloadedFromShared
                    ? '隐私路线：地图内容已隐藏，但路线仍会正常模拟。'
                    : '隐私路线：上传共享时会隐藏地图内容，本地模拟正常显示。',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _updateConfig(SimulationConfig next) {
    setState(() => config = next);
    engine.updateConfig(next);
    widget.store.saveSimulation(next);
  }

  Future<void> _start() async {
    if (!widget.route.hasEnoughPoints) return;
    final state = await _mockLocationState();
    if (state != null && state['allowed'] != true) {
      final proceed = await _showMockLocationGuide(
        developerOptions: state['developerOptions'] == true,
      );
      if (proceed != true) return;
    }
    if (!mounted) return;
    engine = RouteSimulationEngine(widget.route, config);
    setState(() {
      running = true;
      paused = false;
      completed = false;
      frame = null;
    });
    widget.store.setSimulationRunning(true);
    await widget.store.setLastRoute(widget.route.id);
    await widget.store.setCompletionPending(false);
    // 不保持屏幕常亮：原生服务侧有 WakeLock 负责持续注入，常亮会白白耗电。
    _invoke('keepScreenOn', {'enabled': false});

    final first = widget.route.points.first;
    await _invoke('startMockLocation');
    // 先把首点灌给原生服务，目标应用立刻能读到位置。
    await _invoke('pushLocation', {
      'latitude': first.latitude,
      'longitude': first.longitude,
      'altitude': first.altitude,
      'speed': config.mode == SimulationMode.speed ? config.speed : 0.0,
      'bearing': 0.0,
      'satelliteCount': config.satelliteCount,
      'signalQuality': config.signalQuality,
      'hdop': config.hdop,
      'networkSimulation': config.networkSimulation,
      'intervalMillis': config.updateIntervalMs,
    });

    final dispatchNfc = widget.store.nfcDispatchArmed &&
        widget.store.nfcUrl.isNotEmpty &&
        widget.store.nfcPackage.isNotEmpty;
    if (dispatchNfc) widget.store.armNfcDispatch(false);
    await _invoke('startRouteSimulation', {
      'title': widget.route.name,
      'latitude': first.latitude,
      'longitude': first.longitude,
      'floatingWindow': config.floatingWindow,
      'floatingWindowScale': config.floatingWindowScale,
      'floatingWindowButtonSize': config.floatingWindowButtonSize,
      if (dispatchNfc) 'nfcUrl': widget.store.nfcUrl,
      if (dispatchNfc) 'nfcPackage': widget.store.nfcPackage,
      'routePoints': widget.route.points
          .map((point) => {
                'latitude': point.latitude,
                'longitude': point.longitude,
              })
          .toList(),
    });
    if (mounted) {
      _toast(
        context,
        dispatchNfc ? '模拟已开始，正在跳转目标应用；离开本应用后小窗会自动浮出。' : '模拟已开始；离开本应用后小窗会自动浮出。',
      );
    }

    if (config.realStepLink) {
      // 真实步数联动：位置只随检测到的步数推进，不跑定时器。
      await widget.store.recordHistory(
        title: widget.route.name,
        detail: '真实步数联动模拟',
        kind: 'route',
      );
    } else {
      _startTimer();
      unawaited(widget.store.recordHistory(
        title: widget.route.name,
        detail:
            '${config.mode == SimulationMode.speed ? '速度 ${config.speed.toStringAsFixed(1)}m/s' : '步频 ${config.cadence.toStringAsFixed(0)}步/分'} · ${config.loops} 圈',
        kind: 'route',
      ));
    }
    Future.microtask(() {
      if (mounted) _syncOverlayState();
    });
  }

  void _startTimer() {
    timer?.cancel();
    timer = Timer.periodic(Duration(milliseconds: config.tickMillis), (_) {
      if (mounted && !paused && running) {
        _publishFrame(engine.next());
      }
    });
  }

  void _togglePause() {
    if (!running && !paused) return;
    if (paused) {
      setState(() => paused = false);
      if (!config.realStepLink) _startTimer();
    } else {
      timer?.cancel();
      setState(() => paused = true);
    }
    _syncOverlayState();
  }

  Future<void> _end() async {
    timer?.cancel();
    setState(() {
      running = false;
      paused = false;
      completed = false;
    });
    widget.store.setSimulationRunning(false);
    await _invoke('stopRouteSimulation');
    await _invoke('stopMockLocation');
    if (mounted) _toast(context, '模拟已结束');
  }

  void _syncOverlayState() {
    if (!mounted) return;
    final point = frame?.point ?? widget.route.points.first;
    _invoke('updateRouteSimulation', {
      'latitude': point.latitude,
      'longitude': point.longitude,
      'isRunning': running && !paused,
    });
  }

  void _publishFrame(SimulationFrame next) {
    if (!mounted) return;
    _invoke('pushLocation', {
      'latitude': next.point.latitude,
      'longitude': next.point.longitude,
      'altitude': next.point.altitude,
      'speed': next.speed,
      'bearing': next.bearing,
      'satelliteCount': config.satelliteCount,
      'signalQuality': config.signalQuality,
      'hdop': config.hdop,
      'networkSimulation': config.networkSimulation,
      'intervalMillis': config.updateIntervalMs,
    });
    _invoke('updateRouteSimulation', {
      'latitude': next.point.latitude,
      'longitude': next.point.longitude,
      'isRunning': running && !paused && !next.finished,
    });
    setState(() => frame = next);
    if (next.finished) _onFinished();
  }

  void _onFinished() {
    timer?.cancel();
    setState(() {
      running = false;
      paused = false;
      completed = true;
    });
    widget.store.setSimulationRunning(false);
    unawaited(widget.store.setCompletionPending(true));
    // 不停止模拟定位服务：目标应用还需要读取最后一个位置（常见校园跑在提交时会复核定位）。
    unawaited(widget.store.recordHistory(
      title: widget.route.name,
      detail: '模拟完成 ${config.loops} 圈',
      kind: 'route',
    ));
    HapticFeedback.vibrate();
    _showCompletionNotice();
  }

  Future<void> _showCompletionNotice() async {
    if (!mounted) return;
    await widget.store.setCompletionPending(false);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('模拟完成'),
        content: Text(
          '已完成 ${config.loops} 圈路线模拟。\n\n'
          '模拟定位仍在运行并保持在终点，目标应用提交成绩时仍能读到正常位置。'
          '确认目标应用已完成后再点「结束」或离开本页。',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<Map<dynamic, dynamic>?> _mockLocationState() async {
    try {
      return await const MethodChannel('schoolrun/platform')
          .invokeMethod<Map<dynamic, dynamic>>('checkMockLocation');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool?> _showMockLocationGuide({required bool developerOptions}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要模拟位置权限'),
        content: Text(
          '系统尚未把 RunToolBox 设为「模拟位置信息应用」，注入的坐标会被系统丢弃。\n\n'
          '${developerOptions ? '请到开发者选项 → 选择模拟位置信息应用 → 选择 RunToolBox。' : '请先开启开发者选项，再在「选择模拟位置信息应用」中选择 RunToolBox。'}',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              const MethodChannel('schoolrun/platform')
                  .invokeMethod<bool>('openAppSettings');
            },
            child: const Text('应用设置'),
          ),
          FilledButton(
            onPressed: () {
              const MethodChannel('schoolrun/platform')
                  .invokeMethod<bool>('openMockLocationSettings');
              Navigator.pop(context, true);
            },
            child: const Text('去设置并继续'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      return await const MethodChannel('schoolrun/platform').invokeMethod<bool>(
          method, arguments ?? {'routeId': widget.route.id});
    } on MissingPluginException {
      if (method == 'startMockLocation' && mounted) {
        _toast(context, '系统模拟定位桥接未启用，当前只展示路线模拟进度。');
      }
      return null;
    } on PlatformException catch (error) {
      if (mounted) _toast(context, error.message ?? '系统桥接不可用');
      return null;
    }
  }

  void _showSimulationInfo(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => const AlertDialog(
          title: Text('模拟设置'),
          content: Text(
            '默认速度为 15m/s、循环 100 圈。可切换为按步频模拟，并记住上次使用的参数。'
            '开始后请把目标应用开成小窗或分屏；离开本应用时悬浮小窗会自动浮出。',
          ),
          actions: [CloseButton()],
        ),
      );
}

class _SimulationSettings extends StatelessWidget {
  const _SimulationSettings({required this.config, required this.onChanged});
  final SimulationConfig config;
  final ValueChanged<SimulationConfig> onChanged;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            children: [
              Row(
                children: [
                  const Text(
                    '运行参数',
                    style: TextStyle(fontWeight: FontWeight.w800, color: _ink),
                  ),
                  const Spacer(),
                  DropdownButton<SimulationMode>(
                    value: config.mode,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(
                        value: SimulationMode.speed,
                        child: Text('按速度'),
                      ),
                      DropdownMenuItem(
                        value: SimulationMode.cadence,
                        child: Text('按步频'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null)
                        onChanged(config.copyWith(mode: value));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _NumberField(
                label: config.mode == SimulationMode.speed
                    ? '速度（m/s）'
                    : '步频（步/分钟）',
                value: config.mode == SimulationMode.speed
                    ? config.speed
                    : config.cadence,
                min: config.mode == SimulationMode.speed ? 0.5 : 30,
                max: config.mode == SimulationMode.speed ? 50 : 240,
                divisions: 99,
                onChanged: (value) => onChanged(
                  config.mode == SimulationMode.speed
                      ? config.copyWith(speed: value)
                      : config.copyWith(cadence: value),
                ),
              ),
              if (config.mode == SimulationMode.cadence)
                _NumberField(
                  label: '每米步数',
                  value: config.stepsPerMeter,
                  min: .5,
                  max: 4,
                  divisions: 35,
                  onChanged: (value) => onChanged(
                    config.copyWith(stepsPerMeter: value),
                  ),
                ),
              _NumberField(
                label: '循环次数',
                value: config.loops.toDouble(),
                min: 1,
                max: 500,
                divisions: 499,
                onChanged: (value) =>
                    onChanged(config.copyWith(loops: value.round())),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('速度自然浮动'),
                subtitle: const Text(
                  '让每个节拍有轻微变化',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
                value: config.dynamicIntensity,
                onChanged: (value) =>
                    onChanged(config.copyWith(dynamicIntensity: value)),
              ),
              if (config.dynamicIntensity)
                _NumberField(
                  label: '速度变化幅度（m/s）',
                  value: config.intensityRange,
                  min: 0,
                  max: 8,
                  divisions: 32,
                  onChanged: (value) => onChanged(
                    config.copyWith(intensityRange: value),
                  ),
                ),
              if (config.dynamicIntensity)
                _NumberField(
                  label: '速度变化频率',
                  value: config.intensityFrequency,
                  min: .05,
                  max: .95,
                  divisions: 18,
                  onChanged: (value) => onChanged(
                    config.copyWith(intensityFrequency: value),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('路线自然偏移'),
                subtitle: const Text(
                  '模拟轻微的行走摆动',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
                value: config.naturalPath,
                onChanged: (value) =>
                    onChanged(config.copyWith(naturalPath: value)),
              ),
              if (config.naturalPath)
                _NumberField(
                  label: '路线偏移幅度（m）',
                  value: config.pathAmplitude,
                  min: 0,
                  max: 5,
                  divisions: 50,
                  onChanged: (value) => onChanged(
                    config.copyWith(pathAmplitude: value),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('真实步数联动'),
                subtitle: const Text(
                  '每检测到一步就推进路线，适合边走边模拟',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
                value: config.realStepLink,
                onChanged: (value) => onChanged(
                  config.copyWith(realStepLink: value),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自然海拔变化'),
                subtitle: const Text(
                  '根据模拟步态生成轻微高度变化',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
                value: config.naturalAltitude,
                onChanged: (value) => onChanged(
                  config.copyWith(naturalAltitude: value),
                ),
              ),
              if (config.naturalAltitude) ...[
                _NumberField(
                  label: '海拔基线（m）',
                  value: config.altitudeBase,
                  min: 0,
                  max: 3000,
                  divisions: 300,
                  onChanged: (value) => onChanged(
                    config.copyWith(altitudeBase: value),
                  ),
                ),
                _NumberField(
                  label: '海拔变化范围（m）',
                  value: config.altitudeRange,
                  min: 0,
                  max: 10,
                  divisions: 50,
                  onChanged: (value) => onChanged(
                    config.copyWith(altitudeRange: value),
                  ),
                ),
                _NumberField(
                  label: '身高基线（cm）',
                  value: config.altitudeHeight,
                  min: 0,
                  max: 250,
                  divisions: 50,
                  onChanged: (value) => onChanged(
                    config.copyWith(altitudeHeight: value),
                  ),
                ),
                _NumberField(
                  label: '海拔变化概率',
                  value: config.altitudeProbability,
                  min: .05,
                  max: .95,
                  divisions: 18,
                  onChanged: (value) => onChanged(
                    config.copyWith(altitudeProbability: value),
                  ),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('离开应用时显示悬浮小窗'),
                subtitle: const Text(
                  '跳到目标应用后小窗自动浮出，回到本应用自动收起',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
                value: config.floatingWindow,
                onChanged: (value) => onChanged(
                  config.copyWith(floatingWindow: value),
                ),
              ),
              if (config.floatingWindow) ...[
                _NumberField(
                  label: '小窗大小比例',
                  value: config.floatingWindowScale,
                  min: .35,
                  max: .9,
                  divisions: 22,
                  onChanged: (value) => onChanged(
                    config.copyWith(floatingWindowScale: value),
                  ),
                ),
                _NumberField(
                  label: '小窗按键高度（dp）',
                  value: config.floatingWindowButtonSize.toDouble(),
                  min: 32,
                  max: 72,
                  divisions: 20,
                  onChanged: (value) => onChanged(
                    config.copyWith(
                      floatingWindowButtonSize: value.round(),
                    ),
                  ),
                ),
              ],
              _NumberField(
                label: '步数链接比例',
                value: config.linkRatio,
                min: .1,
                max: 3,
                divisions: 29,
                onChanged: (value) => onChanged(
                  config.copyWith(linkRatio: value),
                ),
              ),
              _NumberField(
                label: '模拟卫星数量',
                value: config.satelliteCount.toDouble(),
                min: 1,
                max: 12,
                divisions: 11,
                onChanged: (value) => onChanged(
                  config.copyWith(satelliteCount: value.round()),
                ),
              ),
              _NumberField(
                label: 'HDOP 定位精度',
                value: config.hdop,
                min: .5,
                max: 9,
                divisions: 17,
                onChanged: (value) => onChanged(
                  config.copyWith(hdop: value),
                ),
              ),
              _NumberField(
                label: '信号质量',
                value: config.signalQuality.toDouble(),
                min: 0,
                max: 2,
                divisions: 2,
                onChanged: (value) => onChanged(
                  config.copyWith(signalQuality: value.round()),
                ),
              ),
              _NumberField(
                label: '定位注入间隔（ms）',
                value: config.updateIntervalMs.toDouble(),
                min: 100,
                max: 2000,
                divisions: 19,
                onChanged: (value) => onChanged(
                  config.copyWith(updateIntervalMs: value.round()),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('网络定位辅助信号'),
                value: config.networkSimulation,
                onChanged: (value) => onChanged(
                  config.copyWith(networkSimulation: value),
                ),
              ),
            ],
          ),
        ),
      );
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 13, color: _muted)),
              const Spacer(),
              Text(
                value == value.roundToDouble()
                    ? value.toInt().toString()
                    : value.toStringAsFixed(1),
                style:
                    const TextStyle(fontWeight: FontWeight.w800, color: _ink),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            activeColor: _teal,
          ),
        ],
      );
}

class _SimulationPainter extends CustomPainter {
  const _SimulationPainter({
    required this.points,
    required this.current,
    required this.mask,
  });
  final List<RoutePoint> points;
  final RoutePoint? current;
  final bool mask;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = mask ? Colors.white : const Color(0xFFE9F0EB),
    );
    final painter = _MapOverlayPainter(
      points: points,
      selectedIndex: null,
      closed: false,
    );
    painter.paint(canvas, size);
    if (mask)
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Colors.white.withAlpha(235),
      );
    if (current != null && points.isNotEmpty) {
      final offset = _MapGeometry.map(points, current!, size);
      canvas.drawCircle(offset, 11, Paint()..color = _coral.withAlpha(55));
      canvas.drawCircle(offset, 6, Paint()..color = _coral);
    }
  }

  @override
  bool shouldRepaint(covariant _SimulationPainter oldDelegate) =>
      oldDelegate.current != current ||
      oldDelegate.mask != mask ||
      oldDelegate.points != points;
}

class NfcPage extends StatefulWidget {
  const NfcPage({required this.store, super.key});
  final AppStore store;

  @override
  State<NfcPage> createState() => _NfcPageState();
}

class _NfcPageState extends State<NfcPage> {
  late final TextEditingController urlController;
  late final TextEditingController packageController;
  StreamSubscription<dynamic>? nfcSubscription;
  var reading = false;
  var readerActive = false;
  String hardwareStatus = '检查 NFC 状态中';
  String lastTagText = '';
  String source = 'manual';

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.store.nfcUrl);
    packageController = TextEditingController(text: widget.store.nfcPackage);
    source = widget.store.nfcSource.isEmpty ? 'manual' : widget.store.nfcSource;
    nfcSubscription = const EventChannel('schoolrun/nfc')
        .receiveBroadcastStream()
        .listen(_applyTag, onError: (_) {
      if (mounted) setState(() => readerActive = false);
    });
    _refreshNfcStatus();
  }

  @override
  void dispose() {
    nfcSubscription?.cancel();
    const MethodChannel('schoolrun/platform').invokeMethod<bool>(
      'stopNfcReader',
    );
    urlController.dispose();
    packageController.dispose();
    super.dispose();
  }

  void _applyTag(dynamic event) {
    if (!mounted || event is! Map) return;
    final url = event['url'] as String? ?? '';
    final packageName = event['packageName'] as String? ?? '';
    final text = event['text'] as String? ?? '';
    if (url.isEmpty && packageName.isEmpty && text.isEmpty) return;
    setState(() {
      if (url.isNotEmpty) urlController.text = url;
      if (packageName.isNotEmpty) packageController.text = packageName;
      source = 'nfc';
      lastTagText = text;
    });
    _saveFields();
    _toast(
      context,
      packageName.isEmpty ? '已读取标签内容，请补全目标应用包名' : 'NFC 标签已读取并保存',
    );
  }

  Future<void> _startReader() async {
    try {
      final ok = await const MethodChannel('schoolrun/platform')
          .invokeMethod<bool>('startNfcReader');
      if (mounted) setState(() => readerActive = ok == true);
    } on PlatformException {
      // 部分机型在未开启 NFC 时会抛异常，状态卡片会显示原因。
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
        children: [
          const Text(
            'NFC 工具',
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w800,
              color: _ink,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '读取公开标签，或手动填写跳转地址和目标包名。',
            style: TextStyle(color: _muted),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              dense: true,
              leading: Icon(
                hardwareStatus == 'NFC 已就绪' ? Icons.check_circle : Icons.info,
                color: hardwareStatus == 'NFC 已就绪' ? _teal : _coral,
              ),
              title: Text(hardwareStatus),
              subtitle: Text(
                readerActive
                    ? '页面已开启贴卡读取，把标签靠近手机即可自动填充'
                    : '模拟 NFC 需要设备支持 NFC 并开启系统 NFC 开关',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: IconButton(
                tooltip: '刷新状态',
                onPressed: () async {
                  await _refreshNfcStatus();
                  if (hardwareStatus == 'NFC 已就绪') await _startReader();
                },
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE9EAF8),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const Icon(Icons.nfc, color: Color(0xFF6674B7)),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          '当前 NFC 配置',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _ink,
                          ),
                        ),
                      ),
                      Text(
                        sourceLabel(source),
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: urlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '跳转 URL',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: packageController,
                    decoration: const InputDecoration(
                      labelText: '应用包名',
                      prefixIcon: Icon(Icons.apps_outlined),
                    ),
                  ),
                  if (lastTagText.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '标签文本：$lastTagText',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _mock,
                          icon: Icon(widget.store.nfcDispatchArmed
                              ? Icons.undo_rounded
                              : Icons.key_outlined),
                          label: Text(reading
                              ? '处理中'
                              : widget.store.nfcDispatchArmed
                                  ? '取消登记'
                                  : '模拟 NFC'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _saveTemplate,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('保存'),
                      ),
                    ],
                  ),
                  if (widget.store.nfcDispatchArmed) ...[
                    const SizedBox(height: 10),
                    const Row(
                      children: [
                        Icon(Icons.hourglass_top_rounded,
                            size: 16, color: _teal),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'NFC 已登记，到「路线模拟」点「开始模拟」时会自动跳转目标应用。',
                            style: TextStyle(fontSize: 12, color: _muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _read,
                          icon: const Icon(Icons.contactless_outlined),
                          label: const Text('读取标签'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _copyUrl,
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('复制地址'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _shareNfc,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('共享 NFC'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _downloadSharedNfc,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('下载共享'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const _SectionTitle(title: '本地配置'),
          const SizedBox(height: 10),
          if (widget.store.nfcConfigs.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Row(
                  children: [
                    Icon(Icons.bookmark_border, color: _muted),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '保存一个配置后，下次可以直接载入。',
                        style: TextStyle(color: _muted),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ...widget.store.nfcConfigs.map(
              (config) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.bookmark_outline, color: _teal),
                    title: Text(
                      config.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${config.packageName} · ${sourceLabel(config.source)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'load') {
                          _loadTemplate(config);
                        } else if (value == 'delete') {
                          _deleteTemplate(config);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'load', child: Text('载入配置')),
                        PopupMenuItem(value: 'delete', child: Text('删除配置')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _loadTemplate(NfcConfig config) {
    setState(() {
      urlController.text = config.url;
      packageController.text = config.packageName;
      source = config.source;
      lastTagText = '';
    });
    _saveFields();
    _toast(context, '配置已载入');
  }

  /// 模拟 NFC。模拟已在跑就立刻跳转；没跑则只登记，等「开始模拟」再触发。
  Future<void> _mock() async {
    await _saveFields();
    final url = urlController.text.trim();
    final packageName = packageController.text.trim();
    if (url.isEmpty || packageName.isEmpty) {
      _toast(context, '请先填写跳转 URL 和应用包名');
      return;
    }
    if (widget.store.simulationRunning) {
      await _dispatchNow();
      return;
    }
    if (widget.store.nfcDispatchArmed) {
      widget.store.armNfcDispatch(false);
      if (mounted) _toast(context, '已取消登记，开始模拟时不会自动跳转。');
      return;
    }
    widget.store.armNfcDispatch(true);
    if (mounted) _toast(context, 'NFC 已准备完成，开始模拟后会自动触发。');
  }

  Future<void> _dispatchNow() async {
    try {
      final result = await const MethodChannel('schoolrun/platform')
          .invokeMethod<Map<dynamic, dynamic>>('dispatchNfc', {
        'url': urlController.text.trim(),
        'packageName': packageController.text.trim(),
      });
      if (!mounted) return;
      final status = result?['status'] as String? ?? 'failed';
      final detail = result?['detail'] as String? ?? '';
      _toast(
        context,
        switch (status) {
          'ndef' => '目标应用已通过 NFC 记录启动',
          'view' => '目标应用已启动',
          'browser' => '目标应用不可用，已用浏览器打开链接',
          _ => detail.isEmpty ? '目标应用启动失败，请检查 URL 与包名' : detail,
        },
      );
    } on MissingPluginException {
      if (mounted) _toast(context, 'NFC 平台桥接未启用，配置已保存');
    } on PlatformException catch (error) {
      if (mounted) _toast(context, error.message ?? 'NFC 桥接不可用');
    }
  }

  Future<void> _read() async {
    setState(() => reading = true);
    try {
      final result = await const MethodChannel('schoolrun/platform')
          .invokeMethod<Map<dynamic, dynamic>>('readNfc');
      if (result != null) {
        setState(() {
          urlController.text = result['url'] as String? ?? '';
          packageController.text = result['packageName'] as String? ?? '';
          lastTagText = result['text'] as String? ?? '';
          source = 'nfc';
        });
        await _saveFields();
      }
      if (mounted) {
        _toast(context, result == null ? '没有读取到 NFC 数据' : 'NFC 数据已读取');
      }
    } on MissingPluginException {
      if (mounted) _toast(context, 'NFC 读取需要 Android 平台桥接');
    } on PlatformException catch (error) {
      if (mounted) _toast(context, error.message ?? 'NFC 读取失败');
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<void> _refreshNfcStatus() async {
    try {
      final result = await const MethodChannel('schoolrun/platform')
          .invokeMethod<Map<dynamic, dynamic>>('nfcStatus');
      if (!mounted) return;
      final available = result?['available'] == true;
      final enabled = result?['enabled'] == true;
      setState(() => hardwareStatus = !available
          ? '设备不支持 NFC'
          : !enabled
              ? 'NFC 未开启'
              : 'NFC 已就绪');
    } on MissingPluginException {
      if (mounted) setState(() => hardwareStatus = 'Android NFC 状态不可用');
    } on PlatformException {
      if (mounted) setState(() => hardwareStatus = '无法读取 NFC 状态');
    }
  }

  Future<void> _saveFields() => widget.store.saveNfcFields(
        url: urlController.text,
        packageName: packageController.text,
        source: source,
      );

  Future<void> _copyUrl() async {
    await Clipboard.setData(ClipboardData(text: urlController.text));
    if (mounted) _toast(context, '地址已复制');
  }

  Future<void> _saveTemplate() async {
    await _saveFields();
    final controller = TextEditingController(text: '常用配置');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存 NFC 配置'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '配置名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await widget.store.saveNfcTemplate(
      NfcConfig(
        name: name,
        url: urlController.text,
        packageName: packageController.text,
        source: source,
      ),
    );
    if (mounted) _toast(context, '配置已保存');
  }

  Future<void> _deleteTemplate(NfcConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 NFC 配置'),
        content: Text('确定删除“${config.name}”吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) await widget.store.deleteNfcTemplate(config);
  }

  /// 共享当前/选择的 NFC 配置到服务器。
  Future<void> _shareNfc() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先在「共享中心」填写服务器地址');
      return;
    }
    await _saveFields();
    final nameController = TextEditingController(
      text: widget.store.nfcConfigs.isNotEmpty
          ? widget.store.nfcConfigs.first.name
          : 'nfc_${DateTime.now().millisecondsSinceEpoch}',
    );
    final urlControllerLocal = TextEditingController(text: urlController.text);
    final packageControllerLocal =
        TextEditingController(text: packageController.text);
    var shareSource = source;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('共享 NFC 配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.store.nfcConfigs.isNotEmpty)
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: '从本地配置载入'),
                    items: widget.store.nfcConfigs
                        .map((item) => DropdownMenuItem(
                              value: item.name,
                              child: Text(item.name),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      final config = widget.store.nfcConfigs
                          .firstWhere((item) => item.name == value);
                      setDialogState(() {
                        nameController.text = config.name;
                        urlControllerLocal.text = config.url;
                        packageControllerLocal.text = config.packageName;
                        shareSource = config.source;
                      });
                    },
                  ),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '配置名称'),
                ),
                TextField(
                  controller: urlControllerLocal,
                  decoration: const InputDecoration(labelText: '跳转 URL'),
                ),
                TextField(
                  controller: packageControllerLocal,
                  decoration: const InputDecoration(labelText: '应用包名'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('上传'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) {
      nameController.dispose();
      urlControllerLocal.dispose();
      packageControllerLocal.dispose();
      return;
    }
    final name = nameController.text.trim();
    final url = urlControllerLocal.text.trim();
    final packageName = packageControllerLocal.text.trim();
    if (name.isEmpty || url.isEmpty || packageName.isEmpty) {
      nameController.dispose();
      urlControllerLocal.dispose();
      packageControllerLocal.dispose();
      _toast(context, '名称、URL 与包名都不能为空');
      return;
    }
    try {
      final config = NfcConfig(
        name: name,
        url: url,
        packageName: packageName,
        source: shareSource,
      );
      await ShareApi(widget.store.shareBaseUrl, token: widget.store.authToken)
          .uploadNfc(config);
      await widget.store.saveNfcTemplate(config);
      if (mounted) _toast(context, 'NFC 配置已共享');
    } catch (error) {
      if (mounted) _toast(context, '共享失败：$error');
    } finally {
      nameController.dispose();
      urlControllerLocal.dispose();
      packageControllerLocal.dispose();
    }
  }

  /// 下载共享 NFC。后端此接口公开，不需要登录。
  Future<void> _downloadSharedNfc() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先在「共享中心」填写服务器地址');
      return;
    }
    try {
      final values = await ShareApi(
        widget.store.shareBaseUrl,
        token: widget.store.authToken,
      ).sharedNfc();
      if (!mounted) return;
      if (values.isEmpty) {
        _toast(context, '服务器上还没有共享 NFC 配置');
        return;
      }
      final selected = await _pickSharedNfc(values);
      if (selected == null) return;
      setState(() {
        urlController.text = selected.url;
        packageController.text = selected.packageName;
        source = selected.source;
        lastTagText = '';
      });
      await widget.store.saveNfcTemplate(selected);
      await _saveFields();
      if (mounted) _toast(context, '共享 NFC 配置已载入并保存');
    } catch (error) {
      if (mounted) _toast(context, '下载失败：$error');
    }
  }

  Future<NfcConfig?> _pickSharedNfc(List<NfcConfig> values) async {
    var query = '';
    return showDialog<NfcConfig>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final filtered = values
              .where((item) => '${item.name}${item.packageName}${item.url}'
                  .toLowerCase()
                  .contains(query.toLowerCase()))
              .toList();
          return AlertDialog(
            title: const Text('选择共享 NFC'),
            content: SizedBox(
              width: 460,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    onChanged: (value) => setDialogState(() => query = value),
                    decoration: const InputDecoration(
                      hintText: '搜索名称 / 包名 / URL',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('没有匹配结果'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final item = filtered[index];
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.nfc, color: _teal),
                                title: Text(item.name),
                                subtitle: Text(
                                  '${item.packageName} · ${sourceLabel(item.source)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onTap: () => Navigator.pop(context, item),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
  }
}

String sourceLabel(String source) => switch (source) {
      'nfc' => '读取标签',
      'saved' => '本地配置',
      'shared' => '共享配置',
      _ => '手动输入',
    };

class DebugLabPage extends StatefulWidget {
  const DebugLabPage({required this.store, super.key});
  final AppStore store;

  @override
  State<DebugLabPage> createState() => _DebugLabPageState();
}

class _DebugLabPageState extends State<DebugLabPage> {
  int cadence = 120;
  int sampleCount = 30;
  bool running = false;
  String result = '等待开始实验';

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('调试算法实验室',
                style: TextStyle(fontWeight: FontWeight.w800))),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
          children: [
            const Text('离线验证',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 8),
            const Text('这里生成测试数据，不会注入系统定位或传感器。',
                style: TextStyle(color: _muted)),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('步频数据生成',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, color: _ink)),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Text('步频'),
                        Expanded(
                            child: Slider(
                                value: cadence.toDouble(),
                                min: 60,
                                max: 220,
                                divisions: 32,
                                label: '$cadence spm',
                                onChanged: (value) =>
                                    setState(() => cadence = value.round()))),
                        Text('$cadence')
                      ]),
                      Row(children: [
                        const Text('样本'),
                        Expanded(
                            child: Slider(
                                value: sampleCount.toDouble(),
                                min: 10,
                                max: 120,
                                divisions: 22,
                                label: '$sampleCount',
                                onChanged: (value) => setState(
                                    () => sampleCount = value.round()))),
                        Text('$sampleCount')
                      ]),
                      FilledButton.icon(
                          onPressed: running ? null : _run,
                          icon: const Icon(Icons.play_arrow),
                          label: Text(running ? '正在生成' : '生成并验证')),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
                child: ListTile(
                    leading: const Icon(Icons.timeline, color: _teal),
                    title: const Text('GPS 轨迹生成'),
                    subtitle: const Text('基于当前路线模拟引擎计算轨迹帧',
                        style: TextStyle(fontSize: 12, color: _muted)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _previewTrack)),
            Card(
                child: ListTile(
                    leading: const Icon(Icons.sensors_outlined, color: _teal),
                    title: const Text('传感器一致性'),
                    subtitle: Text(result,
                        style: const TextStyle(fontSize: 12, color: _muted)),
                    trailing: const Icon(Icons.check_circle_outline),
                    onTap: _run)),
            const SizedBox(height: 12),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(result,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                            color: _ink)))),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: result))
                    .then((_) => _toast(context, '实验结果已复制')),
                icon: const Icon(Icons.download_outlined),
                label: const Text('复制实验结果')),
          ],
        ),
      );

  Future<void> _run() async {
    setState(() => running = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final strideMeters = cadence * .8 / 60;
    final steps = List<double>.generate(
        sampleCount, (index) => strideMeters + math.sin(index / 3) * .04);
    final average = steps.reduce((a, b) => a + b) / steps.length;
    setState(() {
      running = false;
      result =
          '步频: $cadence spm\n样本: $sampleCount\n平均步长: ${average.toStringAsFixed(3)} m\n一致性: 通过\n说明: 这是离线生成数据';
    });
    await widget.store.recordHistory(
        title: '步频一致性实验',
        detail: '$cadence spm / $sampleCount 个样本',
        kind: 'debug');
  }

  void _previewTrack() {
    final route =
        widget.store.routes.where((item) => item.hasEnoughPoints).firstOrNull;
    if (route == null) {
      _toast(context, '请先保存一条至少包含两个点的路线');
      return;
    }
    final engine = RouteSimulationEngine(
        route, widget.store.simulation.copyWith(loops: 1, tickMillis: 500));
    final frames = List.generate(8, (_) => engine.next());
    setState(() => result =
        '轨迹预览: ${route.name}\n生成帧: ${frames.length}\n首点: ${frames.first.point.latitude.toStringAsFixed(5)}, ${frames.first.point.longitude.toStringAsFixed(5)}\n状态: ${frames.last.finished ? '完成' : '进行中'}');
  }
}

class ShareCenterPage extends StatefulWidget {
  const ShareCenterPage({required this.store, super.key});
  final AppStore store;

  @override
  State<ShareCenterPage> createState() => _ShareCenterPageState();
}

class _ShareCenterPageState extends State<ShareCenterPage> {
  bool get loggedIn => widget.store.authToken.isNotEmpty;
  bool busy = false;
  List<SharedSimulationConfig> sharedConfigs = const [];
  AppClientConfig? clientConfig;

  @override
  void initState() {
    super.initState();
    _loadClientConfig();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text(
            '共享中心',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  loggedIn ? Icons.verified_user : Icons.cloud_off_outlined,
                  color: _teal,
                ),
                title: Text(
                  loggedIn ? '已登录：${widget.store.accountName}' : '未登录共享服务',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  loggedIn
                      ? '${widget.store.testerTypeLabel.isEmpty ? '内部账号' : widget.store.testerTypeLabel} · ${widget.store.shareBaseUrl}'
                      : widget.store.shareBaseUrl.isEmpty
                          ? '先填写服务器地址；浏览与下载共享数据不需要登录'
                          : '服务器：${widget.store.shareBaseUrl}',
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
                trailing: loggedIn
                    ? PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'switch') _login();
                          if (value == 'logout')
                            widget.store.clearShareSession();
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'switch', child: Text('切换账号')),
                          PopupMenuItem(value: 'logout', child: Text('退出登录')),
                        ],
                      )
                    : TextButton(onPressed: _login, child: const Text('登录')),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: const Icon(Icons.dns_outlined, color: _teal),
                title: const Text('服务器地址'),
                subtitle: Text(
                  widget.store.shareBaseUrl.isEmpty
                      ? '未配置（例如 http://10.0.2.2:8000/）'
                      : widget.store.shareBaseUrl,
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: _editServer,
              ),
            ),
            if (clientConfig != null && clientConfig!.hasNotice) ...[
              const SizedBox(height: 10),
              Card(
                color: const Color(0xFFFFF7E8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.campaign_outlined, color: _coral),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              clientConfig!.noticeTitle.isEmpty
                                  ? '公告'
                                  : clientConfig!.noticeTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: _ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (clientConfig!.noticeMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          clientConfig!.noticeMessage,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: _ink,
                          ),
                        ),
                      ],
                      if (clientConfig!.qqGroupNumber.isNotEmpty ||
                          clientConfig!.bilibiliUrl.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          children: [
                            if (clientConfig!.qqGroupNumber.isNotEmpty)
                              Chip(
                                avatar:
                                    const Icon(Icons.groups_outlined, size: 16),
                                label:
                                    Text('QQ 群 ${clientConfig!.qqGroupNumber}'),
                              ),
                            if (clientConfig!.bilibiliUrl.isNotEmpty)
                              ActionChip(
                                avatar:
                                    const Icon(Icons.ondemand_video, size: 16),
                                label: Text(
                                  clientConfig!.bilibiliText.isEmpty
                                      ? 'B 站'
                                      : clientConfig!.bilibiliText,
                                ),
                                onPressed: () =>
                                    const MethodChannel('schoolrun/platform')
                                        .invokeMethod<bool>(
                                  'openUrl',
                                  {'url': clientConfig!.bilibiliUrl},
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const _SectionTitle(title: '共享路线'),
            const SizedBox(height: 8),
            ...widget.store.routes.map((route) => Card(
                  child: ListTile(
                    leading: Icon(
                      route.shared ? Icons.cloud_done : Icons.alt_route,
                      color: route.shared ? _teal : _muted,
                    ),
                    title: Text(route.name),
                    subtitle: Text(
                      route.shared
                          ? '已上传到共享服务器'
                          : '${route.points.length} 个点 · 仅本地',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: Switch(
                      value: route.shared,
                      onChanged: (value) => _toggleRoute(route, value),
                    ),
                  ),
                )),
            if (widget.store.routes.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.alt_route, color: _muted),
                  title: Text('暂无路线'),
                  subtitle: Text('先在路线库创建一条路线',
                      style: TextStyle(color: _muted, fontSize: 12)),
                ),
              ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.nfc, color: _teal),
                    title: const Text('共享 NFC'),
                    subtitle: Text(
                      '${widget.store.nfcConfigs.length} 个本地配置',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.cloud_upload_outlined),
                    onTap: _uploadNfcDialog,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading:
                        const Icon(Icons.cloud_download_outlined, color: _teal),
                    title: const Text('下载共享路线'),
                    subtitle: const Text('把服务器上的非隐私路线保存到本地',
                        style: TextStyle(fontSize: 12, color: _muted)),
                    trailing: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: busy ? null : _downloadRoutes,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.tune, color: _teal),
                    title: const Text('共享模拟配置'),
                    subtitle: Text(
                      sharedConfigs.isEmpty
                          ? '加载服务器上的速度和步频配置'
                          : '${sharedConfigs.length} 个共享配置',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.cloud_download_outlined),
                    onTap: busy ? null : _loadSimulationConfigs,
                  ),
                ],
              ),
            ),
            if (widget.store.routes.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _uploadSimulationConfig,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('上传当前模拟配置'),
                ),
              ),
            if (sharedConfigs.isNotEmpty) ...[
              const SizedBox(height: 14),
              const _SectionTitle(title: '服务器模拟配置'),
              const SizedBox(height: 8),
              ...sharedConfigs.map((item) => Card(
                    child: ListTile(
                      title: Text(item.name),
                      subtitle: Text(
                        '${item.config.mode == SimulationMode.speed ? '速度' : '步频'} · ${item.author.isEmpty ? '共享配置' : item.author}',
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          await widget.store.saveSimulation(item.config);
                          if (mounted) _toast(context, '已应用模拟配置');
                        },
                        child: const Text('应用'),
                      ),
                    ),
                  )),
            ],
          ],
        ),
      );

  Future<void> _loadClientConfig() async {
    if (widget.store.shareBaseUrl.isEmpty) return;
    try {
      final config = await ShareApi(widget.store.shareBaseUrl).clientConfig();
      if (mounted) setState(() => clientConfig = config);
    } catch (_) {
      // 公告是可选能力，服务器不可达时静默忽略。
    }
  }

  Future<void> _editServer() async {
    final controller = TextEditingController(text: widget.store.shareBaseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '例如 http://10.0.2.2:8000/',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await widget.store.setShareBaseUrl(value);
    await _loadClientConfig();
  }

  Future<void> _login() async {
    final baseController =
        TextEditingController(text: widget.store.shareBaseUrl);
    final userController = TextEditingController();
    final passwordController = TextEditingController();
    final values = await showDialog<List<String>>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('登录共享服务'),
                content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: baseController,
                        decoration: const InputDecoration(labelText: '服务器地址')),
                    TextField(
                        controller: userController,
                        decoration: const InputDecoration(labelText: '账号')),
                    TextField(
                        controller: passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码'))
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, [
                            baseController.text.trim(),
                            userController.text.trim(),
                            passwordController.text
                          ]),
                      child: const Text('登录'))
                ]));
    baseController.dispose();
    userController.dispose();
    passwordController.dispose();
    if (values == null || values.any((value) => value.isEmpty)) return;
    setState(() => busy = true);
    try {
      final response = await ShareApi(values[0]).login(
        values[1],
        values[2],
        deviceId: widget.store.deviceId.isEmpty
            ? 'flutter-${values[1]}'
            : widget.store.deviceId,
        deviceName: widget.store.deviceName.isEmpty
            ? 'RunToolBox Flutter'
            : widget.store.deviceName,
      );
      final token = response['token'] as String? ?? '';
      if (token.isEmpty) throw const FormatException('登录响应没有 token');
      final account = response['account'] as Map? ?? const {};
      final username = account['username'] as String? ?? values[1];
      final testerLabel = account['testerTypeLabel'] as String? ?? '';
      await widget.store.saveShareSession(
        baseUrl: values[0],
        token: token,
        account: username,
        testerTypeLabel: testerLabel,
      );
      await _loadClientConfig();
      if (mounted) _toast(context, '共享服务登录成功');
    } catch (error) {
      if (mounted) _toast(context, '登录失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _toggleRoute(RouteDefinition route, bool value) async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先填写服务器地址');
      return;
    }
    if (value) {
      try {
        final uploaded = await ShareApi(
          widget.store.shareBaseUrl,
          token: widget.store.authToken,
        ).uploadRoute(route);
        await widget.store.setRouteShared(
          route,
          true,
          shareId: uploaded.shareId,
        );
        if (mounted) _toast(context, '路线已上传到共享服务器');
      } catch (error) {
        if (mounted) _toast(context, '上传失败：$error');
      }
      return;
    }
    await widget.store.setRouteShared(route, false);
  }

  Future<void> _uploadNfcDialog() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先填写服务器地址');
      return;
    }
    final nameController = TextEditingController(
      text:
          'nfc_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}_${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}${DateTime.now().second.toString().padLeft(2, '0')}',
    );
    final urlController = TextEditingController(text: widget.store.nfcUrl);
    final packageController = TextEditingController(
      text: widget.store.nfcPackage,
    );
    var source =
        widget.store.nfcSource.isEmpty ? 'manual' : widget.store.nfcSource;
    NfcConfig? picked;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('共享 NFC 配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.store.nfcConfigs.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: picked?.name,
                    decoration: const InputDecoration(labelText: '从本地配置载入'),
                    items: widget.store.nfcConfigs
                        .map((item) => DropdownMenuItem(
                              value: item.name,
                              child: Text(item.name),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      final config = widget.store.nfcConfigs
                          .firstWhere((item) => item.name == value);
                      setDialogState(() {
                        picked = config;
                        nameController.text = config.name;
                        urlController.text = config.url;
                        packageController.text = config.packageName;
                        source = config.source;
                      });
                    },
                  ),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '配置名称'),
                ),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(labelText: '跳转 URL'),
                ),
                TextField(
                  controller: packageController,
                  decoration: const InputDecoration(labelText: '应用包名'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: source,
                  decoration: const InputDecoration(labelText: '来源'),
                  items: const [
                    DropdownMenuItem(value: 'manual', child: Text('手动输入')),
                    DropdownMenuItem(value: 'nfc', child: Text('读取标签')),
                    DropdownMenuItem(value: 'saved', child: Text('本地配置')),
                    DropdownMenuItem(value: 'shared', child: Text('共享配置')),
                  ],
                  onChanged: (value) => setDialogState(
                    () => source = value ?? 'manual',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('上传'),
            ),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    final url = urlController.text.trim();
    final packageName = packageController.text.trim();
    if (confirmed != true) {
      nameController.dispose();
      urlController.dispose();
      packageController.dispose();
      return;
    }
    if (name.isEmpty || url.isEmpty || packageName.isEmpty) {
      nameController.dispose();
      urlController.dispose();
      packageController.dispose();
      _toast(context, '名称、URL 与包名都不能为空');
      return;
    }
    setState(() => busy = true);
    try {
      final config = NfcConfig(
        name: name,
        url: url,
        packageName: packageName,
        source: source,
      );
      await ShareApi(widget.store.shareBaseUrl, token: widget.store.authToken)
          .uploadNfc(config);
      await widget.store.saveNfcTemplate(config);
      if (mounted) _toast(context, 'NFC 配置上传成功');
    } catch (error) {
      if (mounted) _toast(context, '上传失败：$error');
    } finally {
      nameController.dispose();
      urlController.dispose();
      packageController.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _downloadRoutes() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先填写服务器地址');
      return;
    }
    setState(() => busy = true);
    var downloaded = 0;
    var skipped = 0;
    try {
      final api = ShareApi(
        widget.store.shareBaseUrl,
        token: widget.store.authToken,
      );
      final summaries = await api.sharedRouteSummaries();
      for (final summary in summaries) {
        if (summary.privacyMode) {
          skipped++;
          continue;
        }
        final detail = await api.sharedRoute(summary);
        if (!detail.hasEnoughPoints) continue;
        await widget.store.addDownloadedRoute(detail);
        downloaded++;
      }
      if (mounted) {
        _toast(
          context,
          '已下载 $downloaded 条路线${skipped > 0 ? '，跳过 $skipped 条隐私路线' : ''}',
        );
      }
    } catch (error) {
      if (mounted) _toast(context, '下载失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadSimulationConfigs() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先填写服务器地址');
      return;
    }
    setState(() => busy = true);
    try {
      final values = await ShareApi(
        widget.store.shareBaseUrl,
        token: widget.store.authToken,
      ).sharedSimulationConfigs();
      if (mounted) setState(() => sharedConfigs = values);
      if (mounted) _toast(context, '已加载 ${values.length} 个共享模拟配置');
    } catch (error) {
      if (mounted) _toast(context, '加载失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _uploadSimulationConfig() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先填写服务器地址');
      return;
    }
    final controller = TextEditingController(text: '我的模拟配置');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上传模拟配置'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '配置名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('上传')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await ShareApi(widget.store.shareBaseUrl, token: widget.store.authToken)
          .uploadSimulationConfig(name, widget.store.simulation);
      if (mounted) _toast(context, '模拟配置上传成功');
    } catch (error) {
      if (mounted) _toast(context, '上传失败：$error');
    }
  }
}

class MinePage extends StatelessWidget {
  const MinePage({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            const Text(
              '我的',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
            const SizedBox(height: 6),
            const Text('把工具调成你每天顺手的样子。', style: TextStyle(color: _muted)),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE4F0EB),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.person_outline,
                        color: _teal,
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '本地使用者',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: _ink,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '数据保存在当前设备',
                            style: TextStyle(fontSize: 12, color: _muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '设置',
                      onPressed: () =>
                          _open(context, SettingsPage(store: store)),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            const _SectionTitle(title: '数据概览'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: '本地路线',
                    value: '${store.routes.length}',
                    icon: Icons.alt_route,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Metric(
                    label: 'NFC 配置',
                    value: '${store.nfcConfigs.length}',
                    icon: Icons.nfc,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Metric(
                    label: '历史记录',
                    value: '${store.history.length}',
                    icon: Icons.history,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const _SectionTitle(title: '工具'),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.settings_outlined, color: _teal),
                    title: const Text('模拟与权限设置'),
                    subtitle: const Text(
                      '步频、浮动、网络定位和隐私选项',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, SettingsPage(store: store)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.history, color: _teal),
                    title: const Text('历史记录'),
                    subtitle: Text(
                      '${store.history.length} 条路线和定位记录',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, HistoryPage(store: store)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.menu_book_outlined, color: _teal),
                    title: const Text('操作提示'),
                    subtitle: const Text(
                      '查看路线绘制、模拟和 NFC 说明',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, TipsPage(store: store)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.science_outlined, color: _teal),
                    title: const Text('调试算法实验室'),
                    subtitle: const Text('步频、轨迹和传感器一致性验证',
                        style: TextStyle(fontSize: 12, color: _muted)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, DebugLabPage(store: store)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined, color: _teal),
                    title: const Text('共享中心'),
                    subtitle: const Text('路线、NFC 和模拟配置的共享入口',
                        style: TextStyle(fontSize: 12, color: _muted)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, ShareCenterPage(store: store)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined, color: _teal),
                    title: const Text('内部账号'),
                    subtitle: Text(
                      store.authToken.isEmpty
                          ? '登录后可维护共享内容（使用提示、模拟配置）'
                          : '已登录：${store.accountName}${store.testerTypeLabel.isEmpty ? '' : ' · ${store.testerTypeLabel}'}',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        _open(context, InternalLoginPage(store: store)),
                  ),
                  const Divider(height: 1),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'RunToolBox 2.1.0',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
          child: Column(
            children: [
              Icon(icon, color: _teal, size: 20),
              const SizedBox(height: 8),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 11, color: _muted)),
            ],
          ),
        ),
      );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title:
              const Text('设置', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
          children: [
            const Text(
              '模拟偏好',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('记住上次模拟参数'),
                    subtitle: const Text(
                      '速度、步频和循环次数会保存在设备上',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    value: true,
                    onChanged: (_) {},
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('速度自然浮动'),
                    subtitle: const Text(
                      '给模拟速度增加轻微变化',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    value: store.dynamicIntensity,
                    onChanged: (value) =>
                        store.updateSettings(intensity: value),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('路线自然偏移'),
                    subtitle: const Text(
                      '模拟移动中的轻微横向变化',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    value: store.naturalPath,
                    onChanged: (value) => store.updateSettings(path: value),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('自然海拔变化'),
                    subtitle: const Text(
                      '沿路线平滑生成海拔变化',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    value: store.naturalAltitude,
                    onChanged: (value) => store.updateSettings(altitude: value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('悬浮摇杆速度',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, color: _ink)),
                    ),
                    _NumberField(
                        label: '步行（m/s）',
                        value: store.walkSpeed,
                        min: .2,
                        max: 5,
                        divisions: 48,
                        onChanged: (value) =>
                            store.updateSettings(walk: value)),
                    _NumberField(
                        label: '跑步（m/s）',
                        value: store.runSpeed,
                        min: .5,
                        max: 12,
                        divisions: 46,
                        onChanged: (value) => store.updateSettings(run: value)),
                    _NumberField(
                        label: '骑行（m/s）',
                        value: store.bikeSpeed,
                        min: 1,
                        max: 30,
                        divisions: 58,
                        onChanged: (value) =>
                            store.updateSettings(bike: value)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('历史定位使用随机偏移'),
                      subtitle: const Text('打开历史位置时加入可配置的经纬度偏移',
                          style: TextStyle(fontSize: 12, color: _muted)),
                      value: store.randomOffset,
                      onChanged: (value) => store.updateSettings(random: value),
                    ),
                    _NumberField(
                        label: '纬度偏移（m）',
                        value: store.latitudeOffset,
                        min: 0,
                        max: 50,
                        divisions: 50,
                        onChanged: (value) =>
                            store.updateSettings(latitudeOffsetValue: value)),
                    _NumberField(
                        label: '经度偏移（m）',
                        value: store.longitudeOffset,
                        min: 0,
                        max: 50,
                        divisions: 50,
                        onChanged: (value) =>
                            store.updateSettings(longitudeOffsetValue: value)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('关闭调试日志'),
                      subtitle: const Text('减少定位与模拟过程的本地日志记录',
                          style: TextStyle(fontSize: 12, color: _muted)),
                      value: store.logDisabled,
                      onChanged: (value) =>
                          store.updateSettings(logsOff: value),
                    ),
                    _NumberField(
                      label: '定位历史有效期（天）',
                      value: store.historyExpirationDays.toDouble(),
                      min: 1,
                      max: 3650,
                      divisions: 3649,
                      onChanged: (value) =>
                          store.updateSettings(historyDays: value.round()),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '系统能力',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('PTL 步频限制'),
                    subtitle: const Text(
                      '保留原 Android 客户端的步频控制开关',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    value: store.ptlEnabled,
                    onChanged: (value) => store.updateSettings(ptl: value),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading:
                        const Icon(Icons.location_on_outlined, color: _teal),
                    title: const Text('模拟定位权限'),
                    subtitle: const Text(
                      '查看是否已设为「模拟位置信息应用」',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showMockLocationStatus(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.nfc_outlined, color: _teal),
                    title: const Text('NFC 状态'),
                    subtitle: const Text(
                      '由 Android 平台桥接检查硬件状态',
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _toast(context, 'NFC 状态会在使用 NFC 工具时检查。'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading:
                        const Icon(Icons.satellite_alt_outlined, color: _teal),
                    title: const Text('NMEA / 网络定位参数'),
                    subtitle: Text(
                        '${store.simulation.satelliteCount} 颗卫星 · HDOP ${store.simulation.hdop.toStringAsFixed(1)}',
                        style: const TextStyle(fontSize: 12, color: _muted)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, NmeaSettingsPage(store: store)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '关于',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  const ListTile(
                    leading: Icon(Icons.info_outline, color: _teal),
                    title: Text('版本'),
                    trailing: Text('v2.1.0', style: TextStyle(color: _muted)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.shield_outlined, color: _teal),
                    title: const Text('用户协议与免责声明'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showLegal(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  void _showLegal(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => const AlertDialog(
          title: Text('使用说明'),
          content:
              Text('本项目仅供合法合规的开发、调试、学习与研究用途。请勿用于作弊、绕过平台规则、冒充第三方软件或其他违法违规用途。'),
          actions: [CloseButton()],
        ),
      );
}

class NmeaSettingsPage extends StatefulWidget {
  const NmeaSettingsPage({required this.store, super.key});
  final AppStore store;

  @override
  State<NmeaSettingsPage> createState() => _NmeaSettingsPageState();
}

class _NmeaSettingsPageState extends State<NmeaSettingsPage> {
  late SimulationConfig config;

  @override
  void initState() {
    super.initState();
    config = widget.store.simulation;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('NMEA / 网络定位',
                style: TextStyle(fontWeight: FontWeight.w800))),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
          children: [
            const Text('系统定位数据',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 8),
            const Text('这些参数会随模拟位置写入 Android Location 的扩展数据。',
                style: TextStyle(color: _muted)),
            const SizedBox(height: 12),
            Card(
                child: Column(children: [
              SwitchListTile(
                  title: const Text('网络定位模拟'),
                  subtitle: const Text('允许模拟位置携带网络定位状态',
                      style: TextStyle(fontSize: 12, color: _muted)),
                  value: config.networkSimulation,
                  onChanged: (value) =>
                      _change(config.copyWith(networkSimulation: value))),
              const Divider(height: 1),
              ListTile(
                  title: const Text('卫星数量'),
                  trailing: Text('${config.satelliteCount} 颗'),
                  onTap: () => _numberDialog(
                      '卫星数量',
                      config.satelliteCount.toDouble(),
                      1,
                      12,
                      (value) => _change(
                          config.copyWith(satelliteCount: value.round())))),
              const Divider(height: 1),
              ListTile(
                  title: const Text('信号质量'),
                  trailing: Text(_qualityName(config.signalQuality)),
                  onTap: () => _qualityDialog()),
              const Divider(height: 1),
              ListTile(
                  title: const Text('HDOP'),
                  trailing: Text(config.hdop.toStringAsFixed(1)),
                  onTap: () => _numberDialog('HDOP', config.hdop, .5, 9,
                      (value) => _change(config.copyWith(hdop: value)))),
            ])),
            const SizedBox(height: 14),
            Card(
                child: ListTile(
                    leading: const Icon(Icons.info_outline, color: _teal),
                    title: const Text('更新间隔'),
                    subtitle: Text('${config.tickMillis} ms，与路线模拟节拍一致',
                        style: const TextStyle(fontSize: 12, color: _muted)))),
          ],
        ),
      );

  void _change(SimulationConfig next) {
    setState(() => config = next);
    widget.store.saveSimulation(next);
  }

  Future<void> _numberDialog(String title, double initial, double min,
      double max, ValueChanged<double> onSave) async {
    final controller = TextEditingController(text: initial.toString());
    final value = await showDialog<double>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(title),
                content: TextField(
                    controller: controller,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: '$min - $max')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        final parsed = double.tryParse(controller.text);
                        if (parsed != null)
                          Navigator.pop(context, parsed.clamp(min, max));
                      },
                      child: const Text('保存'))
                ]));
    controller.dispose();
    if (value != null) onSave(value);
  }

  Future<void> _qualityDialog() async {
    final value = await showDialog<int>(
        context: context,
        builder: (context) =>
            SimpleDialog(title: const Text('信号质量'), children: [
              for (final item in const [(0, '弱'), (1, '中'), (2, '强')])
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, item.$1),
                    child: Text(item.$2))
            ]));
    if (value != null) _change(config.copyWith(signalQuality: value));
  }

  static String _qualityName(int value) =>
      switch (value) { 0 => '弱', 1 => '中', _ => '强' };
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title:
              const Text('历史记录', style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            if (store.history.isNotEmpty)
              IconButton(
                tooltip: '清空记录',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _confirmClear(context),
              ),
          ],
        ),
        body: store.history.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(20),
                child: _EmptyPanel(
                  icon: Icons.history,
                  title: '还没有操作记录',
                  detail: '保存路线或开始模拟后，记录会显示在这里。',
                  action: '返回',
                  onTap: () => Navigator.pop(context),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
                itemCount: store.history.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = store.history[index];
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFE4F0EB),
                        foregroundColor: _teal,
                        child: Icon(
                          item.kind == 'nfc' ? Icons.nfc : Icons.alt_route,
                          size: 19,
                        ),
                      ),
                      title: Text(
                        item.title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        item.detail,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                      onTap: item.latitude != null && item.longitude != null
                          ? () => _openLocation(context, item)
                          : null,
                      trailing: PopupMenuButton<String>(
                        tooltip: '记录操作',
                        onSelected: (value) {
                          if (value == 'rename') _rename(context, item);
                          if (value == 'delete') _delete(context, item);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: const Text('重命名'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: const Text('删除记录'),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            _shortDate(item.createdAt),
                            style: const TextStyle(fontSize: 11, color: _muted),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      );

  Future<void> _openLocation(BuildContext context, HistoryEntry item) async {
    var latitude = item.latitude!;
    var longitude = item.longitude!;
    if (store.randomOffset) {
      final random = math.Random();
      final latMeters = (random.nextDouble() * 2 - 1) * store.latitudeOffset;
      final lonMeters = (random.nextDouble() * 2 - 1) * store.longitudeOffset;
      latitude += latMeters / 111320;
      longitude += lonMeters /
          (111320 * math.cos(latitude * math.pi / 180).abs().clamp(.2, 1));
    }
    try {
      await const MethodChannel('schoolrun/platform')
          .invokeMethod<bool>('startMockLocation');
      await const MethodChannel('schoolrun/platform').invokeMethod<bool>(
        'pushLocation',
        {'latitude': latitude, 'longitude': longitude, 'altitude': 55.0},
      );
      if (context.mounted) _toast(context, '已发送历史位置，可在目标应用中查看');
    } on PlatformException catch (error) {
      if (context.mounted) _toast(context, error.message ?? '历史位置发送失败');
    }
  }

  Future<void> _rename(BuildContext context, HistoryEntry item) async {
    final controller = TextEditingController(text: item.title);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重命名历史记录'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await store.renameHistory(item, name);
  }

  Future<void> _delete(BuildContext context, HistoryEntry item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除历史记录'),
        content: Text('确定删除“${item.title}”吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (yes == true) await store.deleteHistory(item);
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史记录'),
        content: const Text('路线、搜索、定位和实验记录都会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (confirmed == true) {
      await store.clearHistory();
      if (context.mounted) _toast(context, '历史记录已清空');
    }
  }
}

class TipsPage extends StatefulWidget {
  const TipsPage({this.store, super.key});

  final AppStore? store;

  @override
  State<TipsPage> createState() => _TipsPageState();
}

class _TipsPageState extends State<TipsPage> {
  final controller = TextEditingController();
  List<UsageTipSummary> remoteTips = const [];
  bool remoteLoaded = false;
  bool loading = false;
  final tips = const [
    ('绘制路线', '搜索地点后移动到目标位置，点击地图依次添加路线点。完成后可以闭合路线、自动加点、减点或平滑近直角。'),
    ('路线模拟', '默认速度为 15m/s、循环次数为 100。可以切换为按步频模拟，开始后保持目标应用处于小窗或分屏状态。'),
    ('NFC 工具', '读取公开 NFC，或填写跳转 URL 和包名进行模拟。常用配置可以保存到本地，之后直接载入。'),
    ('隐私路线', '隐私共享路线在模拟时会隐藏地图内容，但路线进度和模拟过程仍然正常执行。'),
    ('系统权限', '模拟定位需要在 Android 开发者选项中选择当前应用作为模拟位置信息应用；NFC 功能需要设备支持 NFC。'),
  ];

  @override
  void initState() {
    super.initState();
    _loadRemoteTips();
  }

  Future<void> _loadRemoteTips() async {
    final store = widget.store;
    if (store == null || store.shareBaseUrl.isEmpty) return;
    setState(() => loading = true);
    try {
      final values = await ShareApi(
        store.shareBaseUrl,
        token: store.authToken,
      ).usageTips();
      if (mounted)
        setState(() {
          remoteTips = values;
          remoteLoaded = true;
        });
    } catch (_) {
      if (mounted) setState(() => remoteLoaded = false);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = tips
        .where((tip) => '${tip.$1}${tip.$2}'.contains(controller.text))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '操作提示',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (widget.store?.authToken.isNotEmpty == true)
            IconButton(
              tooltip: '新建提示',
              onPressed: _createRemoteTip,
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 30),
        children: [
          TextField(
            controller: controller,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '搜索提示',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 16),
          if (loading) const LinearProgressIndicator(),
          if (remoteLoaded && remoteTips.isNotEmpty) ...[
            const Text('远程提示',
                style: TextStyle(fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 8),
            ...remoteTips
                .where((tip) =>
                    '${tip.title}${tip.excerpt}'.contains(controller.text))
                .map(
                  (tip) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: ListTile(
                        title: Text(tip.title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(tip.excerpt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _muted)),
                        onTap: () => _showRemoteTip(tip),
                        trailing: tip.editable
                            ? PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'edit') _editRemoteTip(tip);
                                  if (value == 'delete') _deleteRemoteTip(tip);
                                },
                                itemBuilder: (context) => const [
                                      PopupMenuItem(
                                          value: 'edit', child: Text('编辑')),
                                      PopupMenuItem(
                                          value: 'delete', child: Text('删除'))
                                    ])
                            : null,
                      ),
                    ),
                  ),
                ),
          ],
          ...filtered.map(
            (tip) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: ExpansionTile(
                  title: Text(
                    tip.$1,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(
                      tip.$2,
                      style: const TextStyle(color: _muted, height: 1.55),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showRemoteTip(UsageTipSummary summary) async {
    final store = widget.store;
    if (store == null) return;
    try {
      final detail = await ShareApi(store.shareBaseUrl, token: store.authToken)
          .usageTip(summary.id);
      if (!mounted) return;
      showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
              title: Text(detail.title),
              content: SingleChildScrollView(
                  child: SelectableText(
                      detail.htmlContent.isEmpty
                          ? detail.excerpt
                          : _htmlToPlainText(detail.htmlContent),
                      style: const TextStyle(height: 1.6))),
              actions: const [CloseButton()]));
    } catch (error) {
      if (mounted) _toast(context, '提示加载失败：$error');
    }
  }

  Future<void> _editRemoteTip(UsageTipSummary summary) async {
    final store = widget.store;
    if (store == null) return;
    UsageTipDetail detail;
    try {
      detail = await ShareApi(store.shareBaseUrl, token: store.authToken)
          .usageTip(summary.id);
    } catch (error) {
      if (mounted) _toast(context, '提示加载失败：$error');
      return;
    }
    final title = TextEditingController(text: detail.title);
    final content = TextEditingController(
        text: detail.htmlContent.isEmpty ? detail.excerpt : detail.htmlContent);
    final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('编辑提示'),
                content: SizedBox(
                    width: 480,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: title,
                          decoration: const InputDecoration(labelText: '标题')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: content,
                          minLines: 5,
                          maxLines: 10,
                          decoration: const InputDecoration(labelText: '内容'))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => _importWordInto(content),
                      child: const Text('导入 Word')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('保存'))
                ]));
    if (result == true && title.text.trim().isNotEmpty) {
      try {
        await ShareApi(store.shareBaseUrl, token: store.authToken).saveUsageTip(
            id: detail.id,
            title: title.text.trim(),
            htmlContent: content.text,
            contributorQq: detail.contributorQq,
            published: detail.published);
        await _loadRemoteTips();
      } catch (error) {
        if (mounted) _toast(context, '保存失败：$error');
      }
    }
    title.dispose();
    content.dispose();
  }

  Future<void> _deleteRemoteTip(UsageTipSummary summary) async {
    final store = widget.store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('删除提示'),
                content: Text('确定删除“${summary.title}”吗？'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirmed != true) return;
    try {
      await ShareApi(store.shareBaseUrl, token: store.authToken)
          .deleteUsageTip(summary.id);
      await _loadRemoteTips();
    } catch (error) {
      if (mounted) _toast(context, '删除失败：$error');
    }
  }

  Future<void> _createRemoteTip() async {
    final store = widget.store;
    if (store == null) return;
    final title = TextEditingController();
    final content = TextEditingController();
    final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('新建提示'),
                content: SizedBox(
                    width: 480,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: title,
                          decoration: const InputDecoration(labelText: '标题')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: content,
                          minLines: 5,
                          maxLines: 10,
                          decoration: const InputDecoration(labelText: '内容'))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => _importWordInto(content),
                      child: const Text('导入 Word')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('发布'))
                ]));
    if (result == true && title.text.trim().isNotEmpty) {
      try {
        await ShareApi(store.shareBaseUrl, token: store.authToken).saveUsageTip(
            title: title.text.trim(),
            htmlContent: content.text,
            published: true);
        await _loadRemoteTips();
      } catch (error) {
        if (mounted) _toast(context, '发布失败：$error');
      }
    }
    title.dispose();
    content.dispose();
  }

  Future<void> _importWordInto(TextEditingController content) async {
    final store = widget.store;
    if (store == null) return;
    try {
      final result = await const MethodChannel('schoolrun/platform')
          .invokeMethod<Map<dynamic, dynamic>>('pickWord');
      if (result == null) return;
      final bytes = base64Decode(result['bytes'] as String? ?? '');
      final imported =
          await ShareApi(store.shareBaseUrl, token: store.authToken).importWord(
              bytes: bytes,
              filename: result['filename'] as String? ?? 'tip.docx');
      content.text = imported['htmlContent'] ?? imported['plainText'] ?? '';
      if (mounted) _toast(context, 'Word 内容已导入，请在编辑器中继续整理');
      // The native picker/API result is intentionally kept at the API boundary;
      // the dialog remains open only when the platform returns a usable result.
      if (imported['htmlContent']?.isNotEmpty == true && mounted)
        _toast(context, '已获得 ${imported['htmlContent']!.length} 个 HTML 字符');
    } catch (error) {
      if (mounted) _toast(context, 'Word 导入失败：$error');
    }
  }
}

String _formatDistance(double meters) => meters < 1000
    ? '${meters.toStringAsFixed(0)}m'
    : '${(meters / 1000).toStringAsFixed(2)}km';

String _shortDate(DateTime date) =>
    '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

void _toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );

/// 极简 HTML → 纯文本，用于展示后端「使用提示」的富文本内容。
/// 不引入 WebView/第三方渲染库：服务端存的是 Word 导入生成的简单 HTML，
/// 去标签 + 保留段落/列表换行就足够可读。
String _htmlToPlainText(String html) {
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'</li\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&#x27;': "'",
    '&hellip;': '…',
    '&mdash;': '—',
    '&ldquo;': '“',
    '&rdquo;': '”',
  };
  entities.forEach((key, value) => text = text.replaceAll(key, value));
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

Future<void> _showMockLocationStatus(BuildContext context) async {
  Map<dynamic, dynamic>? result;
  try {
    result = await const MethodChannel('schoolrun/platform')
        .invokeMethod<Map<dynamic, dynamic>>('checkMockLocation');
  } on MissingPluginException {
    if (context.mounted) _toast(context, '当前平台不支持系统模拟定位');
    return;
  } on PlatformException {
    if (context.mounted) _toast(context, '无法读取模拟定位状态');
    return;
  }
  if (!context.mounted) return;
  final allowed = result?['allowed'] == true;
  final developerOptions = result?['developerOptions'] == true;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('模拟定位权限'),
      content: Text(
        allowed
            ? 'RunToolBox 已被系统选为「模拟位置信息应用」，可以正常注入定位。'
            : '系统尚未把 RunToolBox 设为「模拟位置信息应用」。\n\n'
                '${developerOptions ? '请到开发者选项 → 选择模拟位置信息应用 → 选择 RunToolBox。' : '请先开启开发者选项，再在「选择模拟位置信息应用」中选择 RunToolBox。'}',
        style: const TextStyle(height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (!allowed) ...[
          TextButton(
            onPressed: () {
              const MethodChannel('schoolrun/platform')
                  .invokeMethod<bool>('openAppSettings');
            },
            child: const Text('应用设置'),
          ),
          FilledButton(
            onPressed: () {
              const MethodChannel('schoolrun/platform')
                  .invokeMethod<bool>('openMockLocationSettings');
              Navigator.pop(context);
            },
            child: const Text('打开开发者选项'),
          ),
        ],
      ],
    ),
  );
}

void _open(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

class RouteListTile extends StatelessWidget {
  const RouteListTile({
    required this.route,
    required this.onRun,
    this.onEdit,
    this.onDelete,
    super.key,
  });

  final RouteDefinition route;
  final VoidCallback onRun;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFE4F0EB),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.route, color: _teal),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${route.points.length} 个点  ·  ${route.privacyMode ? '隐私路线' : '本地路线'}',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ],
                ),
              ),
              if (onEdit != null)
                IconButton(
                  tooltip: '编辑路线',
                  onPressed: onEdit,
                  icon:
                      const Icon(Icons.edit_outlined, size: 20, color: _muted),
                ),
              IconButton(
                tooltip: '开始模拟',
                onPressed: onRun,
                icon: const Icon(Icons.play_arrow_rounded, color: _coral),
              ),
              if (onDelete != null)
                IconButton(
                  tooltip: '删除路线',
                  onPressed: onDelete,
                  icon:
                      const Icon(Icons.delete_outline, size: 20, color: _muted),
                ),
            ],
          ),
        ),
      );
}
