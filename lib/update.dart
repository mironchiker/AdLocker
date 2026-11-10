import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
const String kRepo = 'mironchiker/AdLocker';

const MethodChannel _platform = MethodChannel('com.adlocker.app/vpn');

class UpdateInfo {
  final String tag;
  final String notes;
  final String url;

  const UpdateInfo({required this.tag, required this.notes, required this.url});
}

Future<void> openExternalUrl(String url) async {
  try {
    await _platform.invokeMethod('openUrl', url);
  } catch (_) {}
}

Future<UpdateInfo?> fetchUpdate() async {
  try {
    final res = await http
        .get(
          Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (data['tag_name'] ?? '').toString();
    final remoteBuild = int.tryParse(tag.split('-').last) ?? 0;
    if (remoteBuild <= kBuildNumber) return null;

    var url = (data['html_url'] ?? 'https://github.com/$kRepo/releases/latest').toString();
    final assets = (data['assets'] as List?) ?? [];
    for (final item in assets) {
      final asset = item as Map<String, dynamic>;
      if ((asset['name'] ?? '').toString().endsWith('.apk')) {
        url = asset['browser_download_url'].toString();
        break;
      }
    }

    return UpdateInfo(
      tag: tag,
      notes: (data['body'] ?? '').toString().trim(),
      url: url,
    );
  } catch (_) {
    return null;
  }
}

Future<void> showUpdateSheet(BuildContext context, UpdateInfo info) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF120724),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_rounded, color: Color(0xFF2196F3)),
                const SizedBox(width: 10),
                const Text(
                  'Доступно обновление',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Новая версия: ${info.tag}',
              style: TextStyle(fontSize: 13, color: Colors.grey[300]),
            ),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                info.notes,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2196F3),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      openExternalUrl(info.url);
                    },
                    child: const Text('Обновить', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3A3A3A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Позже', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
