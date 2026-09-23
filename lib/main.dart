import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const AdLockerApp());
  }, (error, stack) {
    debugPrint('AdLocker runtime error: $error');
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
        scaffoldBackgroundColor: const Color(0xFF090412),
        primaryColor: const Color(0xFF9D4EDD),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9D4EDD),
          secondary: Color(0xFFC77DFF),
          surface: Color(0xFF130924),
        ),
        cardColor: const Color(0xFF1B0E33),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF090412),
          elevation: 0,
        ),
        fontFamily: 'monospace',
      ),
      home: const DashboardScreen(),
    );
  }
}

class DnsLogEntry {
  final String domain;
  final bool blocked;
  final DateTime time;

  DnsLogEntry({
    required this.domain,
    required this.blocked,
    required this.time,
  });
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isActive = false;
  int _blockedCount = 0;
  int _totalQueries = 0;
  int _activeRuleCount = 0;
  RawDatagramSocket? _dnsServer;
  
  final List<DnsLogEntry> _logs = [];
  final Set<String> _blockedDomains = {};

  final List<String> _defaultBlacklist = [
    // Google AdMob & DoubleClick
    'admob.com',
    'googleads.g.doubleclick.net',
    'pagead2.googlesyndication.com',
    'ads.google.com',
    'adservice.google.com',
    'app-measurement.com',
    
    // Unity Ads
    'unityads.unity3d.com',
    'auction.unityads.unity3d.com',
    'webview.unityads.unity3d.com',
    'config.unityads.unity3d.com',
    
    // AppLovin & IronSource
    'applovin.com',
    'applvn.com',
    'ironsrc.mobi',
    'supersonicads.com',
    'is.com',
    
    // Vungle & Mintegral
    'vungle.com',
    'api.vungle.com',
    'mintegral.net',
    'pgl.mintegral.com',
    
    // Яндекс Директ & Метрика
    'an.yandex.ru',
    'appmetrica.yandex.net',
    'adfox.yandex.ru',
    
    // Мобильная телеметрия & трекеры
    'adjust.com',
    'appsflyer.com',
    'branch.io',
    'kochava.com',
  ];

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  @override
  void dispose() {
    _stopDnsServer();
    super.dispose();
  }

  void _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _blockedCount = prefs.getInt('blocked_count') ?? 0;
      _totalQueries = prefs.getInt('total_queries') ?? 0;
      _blockedDomains.addAll(_defaultBlacklist);
      _activeRuleCount = _blockedDomains.length;
    });
  }

  void _persistStats() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('blocked_count', _blockedCount);
    await prefs.setInt('total_queries', _totalQueries);
  }

  Future<void> _startDnsServer() async {
    try {
      _dnsServer = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5353);
      _dnsServer?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _dnsServer?.receive();
          if (datagram != null) {
            _handleDnsPacket(datagram);
          }
        }
      });

      setState(() {
        _isActive = true;
      });
      _notify('AdLocker активирован');
    } catch (e) {
      _notify('Ошибка запуска локального DNS: $e', isError: true);
    }
  }

  void _stopDnsServer() {
    _dnsServer?.close();
    _dnsServer = null;
    setState(() {
      _isActive = false;
    });
    _notify('AdLocker деактивирован');
  }

  void _toggleProtection() {
    if (_isActive) {
      _stopDnsServer();
    } else {
      _startDnsServer();
    }
  }

  void _handleDnsPacket(Datagram packet) {
    if (packet.data.length < 12) return;

    final data = packet.data;
    final domain = _extractDomainName(data, 12);
    if (domain.isEmpty) return;

    _totalQueries++;
    final isBlocked = _shouldBlock(domain);

    if (isBlocked) {
      _blockedCount++;
      _sendBlockedResponse(packet, data);
    } else {
      _forwardDnsQuery(packet, data);
    }

    _persistStats();

    if (mounted) {
      setState(() {
        _logs.insert(
          0,
          DnsLogEntry(
            domain: domain,
            blocked: isBlocked,
            time: DateTime.now(),
          ),
        );
        if (_logs.length > 50) _logs.removeLast();
      });
    }
  }

  String _extractDomainName(Uint8List buffer, int offset) {
    try {
      final parts = <String>[];
      int pos = offset;

      while (pos < buffer.length) {
        final len = buffer[pos++];
        if (len == 0) break;
        if (pos + len > buffer.length) break;
        parts.add(utf8.decode(buffer.sublist(pos, pos + len)));
        pos += len;
      }
      return parts.join('.');
    } catch (_) {
      return '';
    }
  }

  bool _shouldBlock(String domain) {
    final lower = domain.toLowerCase();
    for (final rule in _blockedDomains) {
      if (lower == rule || lower.endsWith('.$rule')) {
        return true;
      }
    }
    return false;
  }

  void _sendBlockedResponse(Datagram packet, Uint8List request) {
    if (request.length < 12) return;

    final response = BytesBuilder();
    response.add([request[0], request[1]]);
    response.add([0x81, 0x80]);
    response.add([0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]);

    int endOfQuestion = 12;
    while (endOfQuestion < request.length && request[endOfQuestion] != 0) {
      endOfQuestion++;
    }
    endOfQuestion += 5;
    if (endOfQuestion <= request.length) {
      response.add(request.sublist(12, endOfQuestion));
    }

    response.add([0xC0, 0x0C]);
    response.add([0x00, 0x01]);
    response.add([0x00, 0x01]);
    response.add([0x00, 0x00, 0x00, 0x3C]);
    response.add([0x00, 0x04]);
    response.add([0x00, 0x00, 0x00, 0x00]);

    _dnsServer?.send(response.toBytes(), packet.address, packet.port);
  }

  void _forwardDnsQuery(Datagram packet, Uint8List request) async {
    RawDatagramSocket? forwardSocket;
    try {
      forwardSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      forwardSocket.send(request, InternetAddress('1.1.1.1'), 53);

      forwardSocket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final resp = forwardSocket?.receive();
          if (resp != null) {
            _dnsServer?.send(resp.data, packet.address, packet.port);
            forwardSocket?.close();
          }
        }
      });

      Future.delayed(const Duration(seconds: 3), () {
        forwardSocket?.close();
      });
    } catch (_) {
      forwardSocket?.close();
    }
  }

  Future<void> _updateRulesFromWeb() async {
    _notify('Загрузка свежих правил...');
    try {
      final res = await http.get(
        Uri.parse('https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts'),
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        int added = 0;
        final lines = res.body.split('\n');
        for (var line in lines) {
          line = line.trim();
          if (line.startsWith('0.0.0.0 ')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final host = parts[1].trim();
              if (host != '0.0.0.0' && host.isNotEmpty) {
                _blockedDomains.add(host);
                added++;
              }
            }
          }
        }
        setState(() {
          _activeRuleCount = _blockedDomains.length;
        });
        _notify('Обновлено! Добавлено: $added');
      }
    } catch (e) {
      _notify('Ошибка обновления правил: $e', isError: true);
    }
  }

  void _notify(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        backgroundColor: isError ? Colors.redAccent[700] : const Color(0xFF9D4EDD),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;

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
              'ADLOCKER',
              style: TextStyle(
                fontFamily: 'monospace',
                letterSpacing: 2.5,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить правила',
            icon: const Icon(Icons.sync_rounded),
            onPressed: _updateRulesFromWeb,
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Center(
            child: GestureDetector(
              onTap: _toggleProtection,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isActive
                      ? primary.withAlpha(50)
                      : Colors.white.withAlpha(10),
                  border: Border.all(
                    color: _isActive ? primary : Colors.grey[700]!,
                    width: 3,
                  ),
                  boxShadow: _isActive
                      ? [
                          BoxShadow(
                            color: primary.withAlpha(120),
                            blurRadius: 30,
                            spreadRadius: 2,
                          )
                        ]
                      : [],
                ),
                child: Icon(
                  Icons.shield_rounded,
                  size: 64,
                  color: _isActive ? Colors.white : Colors.grey[600],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _isActive ? 'ЗАЩИТА АКТИВНА' : 'ЗАЩИТА ВЫКЛЮЧЕНА',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 13,
              color: _isActive ? const Color(0xFF00FF66) : Colors.grey[500],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildStatCard('ЗАБЛОКИРОВАНО', '$_blockedCount', primary),
                const SizedBox(width: 8),
                _buildStatCard('ВСЕГО DNS', '$_totalQueries', const Color(0xFF00E5FF)),
                const SizedBox(width: 8),
                _buildStatCard('ПРАВИЛ', '$_activeRuleCount', const Color(0xFFFF9100)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'ЖИВОЙ ПОТОК ЗАПРОСОВ',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  color: Colors.grey[400],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _logs.isEmpty
                ? Center(
                    child: Text(
                      'Ожидание сетевых DNS-запросов...',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      final item = _logs[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: item.blocked
                                ? Colors.redAccent.withAlpha(100)
                                : Colors.white.withAlpha(15),
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
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
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
                fontSize: 18,
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

