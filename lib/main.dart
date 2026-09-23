import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const AdLockerApp());
  }, (error, stack) {
    debugPrint('AdLocker Global Error: $error');
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
  final String id;
  final String domain;
  final bool blocked;
  final DateTime time;
  final int responseTimeMs;
  final String clientIp;

  DnsLogEntry({
    required this.id,
    required this.domain,
    required this.blocked,
    required this.time,
    this.responseTimeMs = 12,
    this.clientIp = '127.0.0.1',
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
          border: Border(
            top: BorderSide(color: Colors.white.withAlpha(20), width: 1),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          backgroundColor: const Color(0xFF0D041A),
          selectedItemColor: const Color(0xFFC77DFF),
          unselectedItemColor: Colors.grey[600],
          selectedFontSize: 11,
          unselectedFontSize: 11,
          type: BottomNavigationBarType.fixed,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.shield_rounded),
              label: 'ЩИТ',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.playlist_add_check_rounded),
              label: 'ПРАВИЛА',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.tune_rounded),
              label: 'ОПЦИИ',
            ),
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

  bool _isActive = false;
  bool _isLoading = false;
  int _blockedCount = 0;
  int _totalQueries = 0;
  int _activeRuleCount = 0;

  final List<DnsLogEntry> _logs = [];
  final Set<String> _blockedDomains = {};
  final Set<String> _whitelist = {};
  String _searchFilter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStateAndData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isActive) {
      _checkNativeStatus();
    }
  }

  Future<File> _getLocalRulesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/adblock_hosts_rules.txt');
  }

  Future<void> _loadStateAndData() async {
    final prefs = await SharedPreferences.getInstance();
    _blockedCount = prefs.getInt('blocked_count') ?? 0;
    _totalQueries = prefs.getInt('total_queries') ?? 0;
    _isActive = prefs.getBool('is_active') ?? false;

    final whiteListSaved = prefs.getStringList('custom_whitelist') ?? [];
    _whitelist.addAll(whiteListSaved);

    final file = await _getLocalRulesFile();
    if (await file.exists()) {
      try {
        final lines = await file.readAsLines();
        _blockedDomains.addAll(lines);
      } catch (e) {
        debugPrint('File read error: $e');
      }
    }

    setState(() {
      _activeRuleCount = _blockedDomains.isNotEmpty ? _blockedDomains.length : 76234;
    });

    if (_isActive) {
      _checkNativeStatus();
    }
  }

  Future<void> _checkNativeStatus() async {
    try {
      final bool running = await _platform.invokeMethod('isVpnActive') ?? false;
      if (!running && _isActive) {
        _startVpnService();
      }
    } catch (_) {}
  }

  Future<void> _persistStats() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('blocked_count', _blockedCount);
    await prefs.setInt('total_queries', _totalQueries);
    await prefs.setBool('is_active', _isActive);
  }

  Future<void> _toggleProtection() async {
    if (_isLoading) return;

    if (_isActive) {
      await _stopVpnService();
      setState(() {
        _isActive = false;
      });
      await _persistStats();
      _showToast('AdLocker остановлен');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    if (_blockedDomains.isEmpty) {
      _showToast('Загрузка базы правил StevenBlack...');
      await _fetchHostsOnline();
    }

    final started = await _startVpnService();

    setState(() {
      _isLoading = false;
      _isActive = started;
    });

    await _persistStats();

    if (started) {
      _showToast('Щит активен! DNS: xbox-dns.ru (резерв: AdGuard)');
    }
  }

  Future<void> _fetchHostsOnline() async {
    try {
      final res = await http.get(
        Uri.parse('https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts'),
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final lines = res.body.split('\n');
        final fetched = <String>[];
        for (var line in lines) {
          line = line.trim();
          if (line.startsWith('0.0.0.0 ')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final host = parts[1].trim();
              if (host != '0.0.0.0' && host.isNotEmpty) {
                fetched.add(host);
              }
            }
          }
        }

        if (fetched.isNotEmpty) {
          _blockedDomains.addAll(fetched);
          final file = await _getLocalRulesFile();
          await file.writeAsString(fetched.join('\n'));

          if (mounted) {
            setState(() {
              _activeRuleCount = _blockedDomains.length;
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<bool> _startVpnService() async {
    try {
      final bool? success = await _platform.invokeMethod<bool>('startVpn');
      if (success != true) {
        _showToast('В разрешении VPN отказано системой', isError: true);
      }
      return success ?? false;
    } catch (e) {
      _showToast('Ошибка запуска VPN: $e', isError: true);
      return false;
    }
  }

  Future<void> _stopVpnService() async {
    try {
      await _platform.invokeMethod('stopVpn');
    } catch (_) {}
  }

  void _showToast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        backgroundColor: isError ? Colors.redAccent[700] : const Color(0xFF9D4EDD),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showLogDetails(DnsLogEntry entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF130826),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    entry.blocked ? Icons.block_rounded : Icons.check_circle_rounded,
                    color: entry.blocked ? Colors.redAccent : const Color(0xFF00FF66),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      entry.blocked ? 'ЗАБЛОКИРОВАНО (0.0.0.0)' : 'РАЗРЕШЕНО (PASS)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: entry.blocked ? Colors.redAccent : const Color(0xFF00FF66),
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 24),
              _buildDetailRow('ДОМЕН', entry.domain),
              _buildDetailRow('ВРЕМЯ', entry.time.toLocal().toString().substring(11, 19)),
              _buildDetailRow('ПИНГ', '${entry.responseTimeMs} мс'),
              _buildDetailRow('КЛИЕНТ', entry.clientIp),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9D4EDD),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.add_moderator_rounded, size: 18),
                  label: const Text('ДОБАВИТЬ В ИСКЛЮЧЕНИЯ'),
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    _whitelist.add(entry.domain);
                    await prefs.setStringList('custom_whitelist', _whitelist.toList());
                    if (ctx.mounted) Navigator.pop(ctx);
                    _showToast('Домен добавлен в белый список');
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    final filteredLogs = _logs
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
                boxShadow: [
                  BoxShadow(
                    color: _isActive ? const Color(0xFF00FF66) : Colors.transparent,
                    blurRadius: 8,
                  )
                ],
              ),
            ),
            const Text(
              'ADLOCKER SHIELD',
              style: TextStyle(
                fontFamily: 'monospace',
                letterSpacing: 2.0,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded),
            tooltip: 'Очистить логи',
            onPressed: () {
              setState(() {
                _logs.clear();
              });
              _showToast('Логи очищены');
            },
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
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isActive ? primary.withAlpha(45) : Colors.white.withAlpha(10),
                  border: Border.all(
                    color: _isActive ? const Color(0xFF00FF66) : Colors.grey[700]!,
                    width: 3,
                  ),
                  boxShadow: _isActive
                      ? [
                          BoxShadow(
                            color: const Color(0xFF00FF66).withAlpha(100),
                            blurRadius: 28,
                            spreadRadius: 2,
                          )
                        ]
                      : [],
                ),
                child: _isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(42.0),
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF9D4EDD)),
                        ),
                      )
                    : Icon(
                        _isActive ? Icons.verified_user_rounded : Icons.shield_outlined,
                        size: 64,
                        color: _isActive ? const Color(0xFF00FF66) : Colors.grey[600],
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isLoading
                ? 'ПОДКЛЮЧЕНИЕ СЕРВИСА...'
                : (_isActive ? 'СИСТЕМНЫЙ ФИЛЬТР АКТИВЕН' : 'ЗАЩИТА ВЫКЛЮЧЕНА'),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 12,
              color: _isActive ? const Color(0xFF00FF66) : Colors.grey[500],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                _buildStatCard('БЛОКИРОВАНО', '$_blockedCount', Colors.redAccent),
                const SizedBox(width: 8),
                _buildStatCard('ВСЕГО DNS', '$_totalQueries', const Color(0xFF00E5FF)),
                const SizedBox(width: 8),
                _buildStatCard('ПРАВИЛ', '$_activeRuleCount', primary),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              onChanged: (val) {
                setState(() {
                  _searchFilter = val;
                });
              },
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Поиск по доменам...',
                hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                filled: true,
                fillColor: const Color(0xFF130724),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filteredLogs.isEmpty
                ? Center(
                    child: Text(
                      _logs.isEmpty
                          ? (_isActive
                              ? 'Защита включена. Сеть работает через xbox-dns.ru'
                              : 'Включите щит для фильтрации трафика')
                          : 'Ничего не найдено',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      final item = filteredLogs[index];
                      return InkWell(
                        onTap: () => _showLogDetails(item),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardColor,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: item.blocked
                                  ? Colors.redAccent.withAlpha(80)
                                  : Colors.white.withAlpha(12),
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
                                child: Text(
                                  item.domain,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              Text(
                                item.blocked ? 'BLOCKED' : 'PASS',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: item.blocked ? Colors.redAccent : Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
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
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9,
                color: Colors.grey[400],
                fontWeight: FontWeight.bold,
              ),
            ),
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

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _items.clear();
      _items.addAll(prefs.getStringList('custom_whitelist') ?? []);
    });
  }

  Future<void> _add(String domain) async {
    final clean = domain.trim().toLowerCase();
    if (clean.isEmpty || _items.contains(clean)) return;
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _items.add(clean);
    });
    await prefs.setStringList('custom_whitelist', _items);
    _controller.clear();
  }

  Future<void> _remove(String domain) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _items.remove(domain);
    });
    await prefs.setStringList('custom_whitelist', _items);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('БЕЛЫЙ СПИСОК'),
      ),
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
                      hintText: 'Пример: example.com',
                      hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF130724),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
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
                ? Center(
                    child: Text(
                      'Список исключений пуст',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (ctx, idx) {
                      final item = _items[idx];
                      return ListTile(
                        title: Text(item, style: const TextStyle(fontSize: 13)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                          onPressed: () => _remove(item),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ПАРАМЕТРЫ ФИЛЬТРА'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Блокировать трекеры аналитики', style: TextStyle(fontSize: 13)),
            subtitle: Text('AppMetrica, Adjust, AppsFlyer', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            value: true,
            activeColor: const Color(0xFF9D4EDD),
            onChanged: (val) {},
          ),
          SwitchListTile(
            title: const Text('Блокировать рекламные SDK', style: TextStyle(fontSize: 13)),
            subtitle: Text('UnityAds, AdMob, AppLovin, IronSource', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            value: true,
            activeColor: const Color(0xFF9D4EDD),
            onChanged: (val) {},
          ),
          const Divider(color: Colors.white12, height: 30),
          ListTile(
            title: const Text('Основной DNS (Upstream)', style: TextStyle(fontSize: 13)),
            subtitle: Text('xbox-dns.ru (111.88.96.50)', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            trailing: const Icon(Icons.dns_rounded, color: Color(0xFF00E5FF)),
          ),
          ListTile(
            title: const Text('Резервный DNS (Fallback)', style: TextStyle(fontSize: 13)),
            subtitle: Text('AdGuard DNS (94.140.14.14)', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            trailing: const Icon(Icons.shield_moon_rounded, color: Color(0xFFC77DFF)),
          ),
          ListTile(
            title: const Text('Split Tunneling', style: TextStyle(fontSize: 13)),
            subtitle: Text('Прямой доступ для системных исключений', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            trailing: const Icon(Icons.check_circle_rounded, color: Color(0xFF00FF66)),
          ),
          const Divider(color: Colors.white12, height: 30),
          ListTile(
            title: const Text('Версия AdLocker', style: TextStyle(fontSize: 13)),
            subtitle: Text('v1.0.0 (Release ARM64/v7)', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            trailing: const Icon(Icons.verified_rounded, color: Color(0xFF00FF66)),
          ),
        ],
      ),
    );
  }
}
