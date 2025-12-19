// Service quản lý cập nhật ứng dụng tự động
// - Check version từ GitHub
// - Download file cập nhật
// - Tự động cài đặt (Windows) hoặc mở cài đặt (Android)

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

/// Model chứa thông tin version
class AppVersionInfo {
  final String version;
  final int build;
  final String releaseDate;
  final String releaseNotes;
  final Map<String, String> downloadUrl;
  final bool required;
  final String minVersion;

  AppVersionInfo({
    required this.version,
    required this.build,
    required this.releaseDate,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.required,
    required this.minVersion,
  });

  factory AppVersionInfo.fromJson(Map<String, dynamic> json) {
    return AppVersionInfo(
      version: json['version'] ?? '1.0.0',
      build: json['build'] ?? 1,
      releaseDate: json['releaseDate'] ?? '',
      releaseNotes: json['releaseNotes'] ?? '',
      downloadUrl: Map<String, String>.from(json['downloadUrl'] ?? {}),
      required: json['required'] ?? false,
      minVersion: json['minVersion'] ?? '1.0.0',
    );
  }
}

/// Singleton service quản lý update
class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  // URL file version.json trên GitHub (raw content)
  static const String _versionUrl = 
    'https://raw.githubusercontent.com/ANHDOO/idmav_app/main/version.json';

  AppVersionInfo? _latestVersion;
  String? _currentVersion;
  
  /// Lấy version hiện tại của app
  Future<String> getCurrentVersion() async {
    if (_currentVersion != null) return _currentVersion!;
    
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;
      return _currentVersion!;
    } catch (e) {
      debugPrint('❌ Lỗi lấy version: $e');
      return '1.0.0';
    }
  }

  /// Check xem có bản update mới không
  /// Returns: AppVersionInfo nếu có bản mới, null nếu đã mới nhất
  Future<AppVersionInfo?> checkForUpdate() async {
    try {
      debugPrint('🔍 Đang kiểm tra cập nhật...');
      
      final response = await http.get(Uri.parse(_versionUrl))
          .timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _latestVersion = AppVersionInfo.fromJson(data);
        
        final currentVersion = await getCurrentVersion();
        
        debugPrint('📦 Version hiện tại: $currentVersion');
        debugPrint('🆕 Version mới nhất: ${_latestVersion!.version}');
        
        if (_isNewerVersion(_latestVersion!.version, currentVersion)) {
          debugPrint('✅ Có bản cập nhật mới!');
          return _latestVersion;
        } else {
          debugPrint('✅ Đã là bản mới nhất');
          return null;
        }
      } else {
        debugPrint('⚠️ Không thể kiểm tra cập nhật: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Lỗi kiểm tra cập nhật: $e');
      return null;
    }
  }

  /// So sánh version (VD: "1.1.0" > "1.0.0")
  bool _isNewerVersion(String newVersion, String currentVersion) {
    List<int> newParts = newVersion.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    List<int> currentParts = currentVersion.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    
    // Đảm bảo cả 2 list có 3 phần tử
    while (newParts.length < 3) newParts.add(0);
    while (currentParts.length < 3) currentParts.add(0);
    
    for (int i = 0; i < 3; i++) {
      if (newParts[i] > currentParts[i]) return true;
      if (newParts[i] < currentParts[i]) return false;
    }
    return false;
  }

  /// Download và cài đặt update
  /// [onProgress]: Callback tiến độ download (0.0 - 1.0)
  Future<bool> downloadAndInstall({
    required AppVersionInfo versionInfo,
    Function(double progress)? onProgress,
  }) async {
    try {
      // Xác định platform và URL download
      String? downloadUrl;
      String fileName;
      
      if (Platform.isWindows) {
        downloadUrl = versionInfo.downloadUrl['windows'];
        fileName = 'idmav_app_update.zip';
      } else if (Platform.isAndroid) {
        downloadUrl = versionInfo.downloadUrl['android'];
        fileName = 'idmav_app_update.apk';
      } else {
        debugPrint('⚠️ Platform không được hỗ trợ');
        return false;
      }
      
      if (downloadUrl == null || downloadUrl.isEmpty) {
        debugPrint('⚠️ Không có link download cho platform này');
        return false;
      }
      
      debugPrint('📥 Bắt đầu download: $downloadUrl');
      
      // Lấy thư mục download
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      
      // Download file với progress
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await http.Client().send(request);
      
      if (response.statusCode != 200) {
        debugPrint('❌ Download thất bại: ${response.statusCode}');
        return false;
      }
      
      final contentLength = response.contentLength ?? 0;
      int received = 0;
      List<int> bytes = [];
      
      await for (var chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        
        if (contentLength > 0 && onProgress != null) {
          onProgress(received / contentLength);
        }
      }
      
      // Ghi file
      await file.writeAsBytes(bytes);
      debugPrint('✅ Download hoàn tất: $filePath');
      
      // Cài đặt
      if (Platform.isWindows) {
        return await _installWindows(filePath);
      } else if (Platform.isAndroid) {
        return await _installAndroid(filePath);
      }
      
      return false;
    } catch (e) {
      debugPrint('❌ Lỗi download/install: $e');
      return false;
    }
  }

  /// Cài đặt trên Windows
  Future<bool> _installWindows(String zipPath) async {
    try {
      debugPrint('🔧 Đang giải nén và cài đặt...');
      
      // Lấy thư mục hiện tại của app
      final appDir = Directory.current.path;
      final updateDir = '${Directory.systemTemp.path}\\idmav_update';
      
      // Giải nén file zip
      // Sử dụng PowerShell để giải nén
      final extractResult = await Process.run('powershell', [
        '-Command',
        'Expand-Archive -Path "$zipPath" -DestinationPath "$updateDir" -Force'
      ]);
      
      if (extractResult.exitCode != 0) {
        debugPrint('❌ Giải nén thất bại: ${extractResult.stderr}');
        return false;
      }
      
      debugPrint('✅ Giải nén xong');
      
      // Tạo script batch để copy và restart
      final batchScript = '''
@echo off
timeout /t 2 /nobreak > nul
xcopy /Y /E "$updateDir\\*" "$appDir\\"
start "" "$appDir\\idmav_app.exe"
del "%~f0"
''';
      
      final batchPath = '${Directory.systemTemp.path}\\idmav_update.bat';
      await File(batchPath).writeAsString(batchScript);
      
      // Chạy script và đóng app
      await Process.start('cmd', ['/c', batchPath], 
        mode: ProcessStartMode.detached);
      
      debugPrint('🔄 Đang restart app...');
      exit(0); // Đóng app để script cập nhật
      
    } catch (e) {
      debugPrint('❌ Lỗi cài đặt Windows: $e');
      return false;
    }
  }

  /// Cài đặt trên Android
  Future<bool> _installAndroid(String apkPath) async {
    try {
      debugPrint('📱 Mở cài đặt APK...');
      
      // Mở file APK để cài đặt
      final result = await OpenFilex.open(apkPath);
      
      if (result.type == ResultType.done) {
        debugPrint('✅ Đã mở installer');
        return true;
      } else {
        debugPrint('⚠️ Không thể mở APK: ${result.message}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Lỗi cài đặt Android: $e');
      return false;
    }
  }
}
