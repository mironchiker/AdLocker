import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yandex_mobileads/mobile_ads.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const AdLockerApp());
  }, (error, stack) {
    debugPrint('AdLocker Error: $error');
  });
}

class AdLockerApp extends StatelessWidget {
  const AdLockerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AdLocker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF07020D),
        primaryColor: const Color(0xFF9D4EDD),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9D4EDD),
          secondary: Color(0xFFC77DFF),
          surface: Color(0xFF120724),
        ),
        cardColor: const Color(0xFF190B33),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF07020D),
          elevation: 0,
        ),
        fontFamily: 'monospace',
      ),
      home: const MainNavigationScreen(),
    );
  }
}

class DnsLogEntry {
  final String domain;
  final bool blocked;
  final DateTime time;

  const DnsLogEntry({
    required this.domain,
    required this.blocked,
    required this.time,
  });
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          DashboardView(),
          WhitelistView(),
          SettingsView(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white.withAlpha(20), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          backgroundColor: const Color(0xFF0D041A),
          selectedItemColor: const Color(0xFFC77DFF),
          unselectedItemColor: Colors.grey[600],
          selectedFontSize: 11,
          unselectedFontSize: 11,
          type: BottomNavigationBarType.fixed,
          onTap: (index) => setState(() => _currentIndex = index),
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.shield_rounded), label: 'ЩИТ'),
            BottomNavigationBarItem(icon: Icon(Icons.playlist_add_check_rounded), label: 'БЕЛЫЙ СПИСОК'),
            BottomNavigationBarItem(icon: Icon(Icons.monetization_on_rounded), label: 'МОНЕТИЗАЦИЯ'),
          ],
        ),
      ),
    );
  }
}

class DashboardView extends StatefulWidget {
  const DashboardView({super.key});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> with WidgetsBindingObserver {
  static const _platform = MethodChannel('com.adlocker.app/vpn');
  static const _eventChannel = EventChannel('com.adlocker.app/dns_stream');

  bool _isActive = false;
  bool _isLoading = false;
  int _blockedCount = 0;
  int _totalQueries = 0;
  int _rulesCount = 0;
  bool _isForeground = true;

  StreamSubscription? _dnsSubscription;
  final List<DnsLogEntry> _logs = [];
  String _searchFilter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialData();
    _startNativeStreamListener();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    _dnsSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startNativeStreamListener() {
    _dnsSubscription = _eventChannel.receiveBroadcastStream().listen((dynamic event) {
      if (event is Map) {
        final domain = event['domain']?.toString() ?? '';
        final blocked = event['blocked'] == true;
        final timeMs = (event['time'] as int?) ?? DateTime.now().millisecondsSinceEpoch;

        if (domain.isNotEmpty) {
          _totalQueries++;
          if (blocked) _blockedCount++;

          if (_isForeground && mounted) {
            setState(() {
              _logs.insert(
                0,
                DnsLogEntry(
                  domain: domain,
                  blocked: blocked,
                  time: DateTime.fromMillisecondsSinceEpoch(timeMs),
                ),
              );
              if (_logs.length > 50) _logs.removeLast();
            });
          }
        }
      }
    });
  }

  Future<File> _getRulesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/adblock_hosts_rules.txt');
  }

  Future<void> _loadInitialData() async {
    final file = await _getRulesFile();
    int count = 0;
    if (await file.exists()) {
      try {
        final lines = await file.readAsLines();
        count = lines.length;
      } catch (_) {}
    }

    try {
      final bool running = await _platform.invokeMethod('isVpnActive') ?? false;
      if (mounted) {
        setState(() {
          _isActive = running;
          _rulesCount = count;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _rulesCount = count);
    }
  }

  Future<void> _toggleProtection() async {
    if (_isLoading) return;

    if (_isActive) {
      try {
        await _platform.invokeMethod('stopVpn');
      } catch (_) {}
      setState(() => _isActive = false);
      _showToast('Защита выключена');
      return;
    }

    setState(() => _isLoading = true);

    final file = await _getRulesFile();
    if (!await file.exists() || _rulesCount == 0) {
      _showToast('Загрузка скоростной базы (90k правил)...');
      await _downloadFastRules(file);
    }

    try {
      final bool? started = await _platform.invokeMethod<bool>('startVpn');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isActive = started ?? false;
        });
      }
      if (_isActive) _showToast('Синхоул активен');
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showToast('Ошибка запуска: $e', isError: true);
      }
    }
  }

  Future<void> _downloadFastRules(File file) async {
    final urls = [
      'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts',
      'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt',
    ];

    final hostsSet = <String>{};

    for (final url in urls) {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final lines = const LineSplitter().convert(res.body);
          for (var l in lines) {
            l = l.trim().toLowerCase();
            if (l.isEmpty || l.startsWith('#') || l.startsWith('!')) continue;

            final commentIdx = l.indexOf('#');
            if (commentIdx != -1) l = l.substring(0, commentIdx).trim();

            if (l.startsWith('0.0.0.0 ') || l.startsWith('127.0.0.1 ')) {
              final parts = l.split(RegExp(r'\s+'));
              if (parts.length >= 2) {
                final d = parts[1].trim();
                if (d != '0.0.0.0' && d != 'localhost' && d.contains('.')) {
                  hostsSet.add(d);
                }
              }
            } else if (!l.contains(' ') && l.contains('.')) {
              hostsSet.add(l);
            }
          }
        }
      } catch (_) {}
    }

    hostsSet.addAll([
      'googleads.g.doubleclick.net',
      'pagead2.googlesyndication.com',
      'adservice.google.com',
      'an.yandex.ru',
      'mc.yandex.ru',
      'ads.admob.com',
      'applovin.com',
      'unityads.unity3d.com',
      'ads.tiktok.com',
      'adcolony.com',
    ]);

    if (hostsSet.isNotEmpty) {
      final sink = file.openWrite();
      for (final h in hostsSet) {
        sink.writeln(h);
      }
      await sink.close();

      if (mounted) {
        setState(() => _rulesCount = hostsSet.length);
      }
    }
  }

  void _showToast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        backgroundColor: isError ? Colors.redAccent[700] : const Color(0xFF9D4EDD),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    final filtered = _logs
        .where((e) => e.domain.toLowerCase().contains(_searchFilter.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: _isActive ? const Color(0xFF00FF66) : Colors.grey[600],
                shape: BoxShape.circle,
              ),
            ),
            const Text(
              'ADLOCKER ENGINE',
              style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить базу',
            icon: const Icon(Icons.sync_rounded),
            onPressed: () async {
              _showToast('Скачивание 90k правил...');
              final file = await _getRulesFile();
              await _downloadFastRules(file);
              _showToast('Готово: $_rulesCount правил');
            },
          ),
          IconButton(
            tooltip: 'Очистить лог',
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          Center(
            child: GestureDetector(
              onTap: _toggleProtection,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 135,
                height: 135,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isActive ? primary.withAlpha(45) : Colors.white.withAlpha(10),
                  border: Border.all(
                    color: _isActive ? const Color(0xFF00FF66) : Colors.grey[700]!,
                    width: 3,
                  ),
                ),
                child: _isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(40.0),
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : Icon(
                        _isActive ? Icons.verified_user_rounded : Icons.shield_outlined,
                        size: 60,
                        color: _isActive ? const Color(0xFF00FF66) : Colors.grey[600],
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isLoading
                ? 'ЗАГРУЗКА...'
                : (_isActive ? 'СИНХОУЛ 0.0.0.0 АКТИВЕН' : 'ЗАЩИТА ВЫКЛЮЧЕНА'),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: _isActive ? const Color(0xFF00FF66) : Colors.grey[500],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                _buildStatCard('БЛОК 0.0.0.0', '$_blockedCount', Colors.redAccent),
                const SizedBox(width: 8),
                _buildStatCard('ВСЕГО DNS', '$_totalQueries', const Color(0xFF00E5FF)),
                const SizedBox(width: 8),
                _buildStatCard('ПРАВИЛ', '$_rulesCount', primary),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              onChanged: (v) => setState(() => _searchFilter = v),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Поиск по доменам...',
                hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                filled: true,
                fillColor: const Color(0xFF130724),
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      _logs.isEmpty
                          ? (_isActive ? 'Трафик фильтруется без задержек...' : 'Включите защиту')
                          : 'Ничего не найдено',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, idx) {
                      final item = filtered[idx];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: item.blocked ? Colors.redAccent.withAlpha(90) : Colors.white.withAlpha(12),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.blocked ? Icons.block_rounded : Icons.check_circle_outline,
                              size: 16,
                              color: item.blocked ? Colors.redAccent : const Color(0xFF00FF66),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(item.domain, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                            ),
                            Text(
                              item.blocked ? '0.0.0.0' : 'PASS',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: item.blocked ? Colors.redAccent : Colors.grey[500],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, String value, Color accent) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withAlpha(50)),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: accent)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 9, color: Colors.grey[400], fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class WhitelistView extends StatefulWidget {
  const WhitelistView({super.key});

  @override
  State<WhitelistView> createState() => _WhitelistViewState();
}

class _WhitelistViewState extends State<WhitelistView> {
  final List<String> _items = [];
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<File> _getWlFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/whitelist.txt');
  }

  Future<void> _load() async {
    final f = await _getWlFile();
    if (await f.exists()) {
      final l = await f.readAsLines();
      if (mounted) setState(() => _items.addAll(l));
    }
  }

  Future<void> _add(String domain) async {
    final clean = domain.trim().toLowerCase();
    if (clean.isEmpty || _items.contains(clean)) return;
    setState(() => _items.add(clean));
    final f = await _getWlFile();
    await f.writeAsString(_items.join('\n'));
    _controller.clear();
  }

  Future<void> _remove(String domain) async {
    setState(() => _items.remove(domain));
    final f = await _getWlFile();
    await f.writeAsString(_items.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('БЕЛЫЙ СПИСОК')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Разрешить домен...',
                      filled: true,
                      fillColor: const Color(0xFF130724),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Color(0xFF9D4EDD), size: 32),
                  onPressed: () => _add(_controller.text),
                ),
              ],
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? Center(child: Text('Список пуст', style: TextStyle(color: Colors.grey[600], fontSize: 12)))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (ctx, idx) => ListTile(
                      title: Text(_items[idx], style: const TextStyle(fontSize: 13)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                        onPressed: () => _remove(_items[idx]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  static const String _yandexBlockId = 'R-M-20111481-1';

  late final Future<BannerAdSize> _adSizeFuture;
  late BannerAd _bannerAd;
  bool _isBannerLoaded = false;
  String _adStatus = 'Нажмите кнопку для проверки монетизации';

  @override
  void initState() {
    super.initState();
    _adSizeFuture = BannerAdSize.sticky(width: 320);
  }

  void _loadYandexAd(BannerAdSize adSize) {
    setState(() {
      _adStatus = 'Запрос баннера R-M-20111481-1...';
      _isBannerLoaded = false;
    });

    _bannerAd = BannerAd(
      adUnitId: _yandexBlockId,
      adSize: adSize,
      adRequest: const AdRequest(),
      onAdLoaded: () {
        if (mounted) {
          setState(() {
            _isBannerLoaded = true;
            _adStatus = 'Баннер показан! Доход зачисляется в РСЯ.';
          });
        }
      },
      onAdFailedToLoad: (error) {
        if (mounted) {
          setState(() {
            _isBannerLoaded = false;
            _adStatus = 'Заблокировано синхоулом либо ещё на модерации в РСЯ.';
          });
        }
      },
    );

    _bannerAd.loadAd();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('МОНЕТИЗАЦИЯ И ТЕСТ')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFC3F1D).withAlpha(120)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.monetization_on_rounded, color: Color(0xFFFC3F1D), size: 22),
                    SizedBox(width: 8),
                    Text('БАННЕР РСЯ (R-M-20111481-1)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Доход зачисляется в рублях на баланс кабинета РСЯ. При отключенном щите баннер загружается, при активном — синхоулится.',
                  style: TextStyle(color: Colors.grey[400], fontSize: 11),
                ),
                const SizedBox(height: 12),
                FutureBuilder<BannerAdSize>(
                  future: _adSizeFuture,
                  builder: (context, snapshot) {
                    final adSize = snapshot.data;
                    return ElevatedButton.icon(
                      onPressed: adSize != null ? () => _loadYandexAd(adSize) : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFC3F1D),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                      label: const Text('Загрузить баннер Яндекса', style: TextStyle(color: Colors.white, fontSize: 12)),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(_adStatus, style: TextStyle(color: _isBannerLoaded ? const Color(0xFF00FF66) : Colors.amberAccent, fontSize: 11)),
                const SizedBox(height: 12),
                if (_isBannerLoaded)
                  Center(
                    child: Container(
                      width: 320,
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        border: Border.all(color: Colors.white12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: AdWidget(bannerAd: _bannerAd),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          ListTile(
            title: const Text('Основной Upstream DNS', style: TextStyle(fontSize: 13)),
            subtitle: Text('xbox-dns.ru (111.88.96.50)', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            trailing: const Icon(Icons.dns_rounded, color: Color(0xFF00E5FF)),
          ),
          ListTile(
            title: const Text('Fallback DNS', style: TextStyle(fontSize: 13)),
            subtitle: Text('AdGuard (94.140.14.14)', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            trailing: const Icon(Icons.shield_moon_rounded, color: Color(0xFFC77DFF)),
          ),
        ],
      ),
    );
  }
}
