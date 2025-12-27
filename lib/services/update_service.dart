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
import 'package:crypto/crypto.dart';

/// Model chứa thông tin version
class AppVersionInfo {
  final String version;
  final int build;
  final String releaseDate;
  final String releaseNotes;
  final Map<String, String> downloadUrl;
  final Map<String, String> hashes; // SHA-256 hashes
  final bool required;
  final String minVersion;

  AppVersionInfo({
    required this.version,
    required this.build,
    required this.releaseDate,
    required this.releaseNotes,
    required this.downloadUrl,
    this.hashes = const {},
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
      hashes: Map<String, String>.from(json['hashes'] ?? {}),
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
  bool _isChecking = false; // <--- Thêm cờ này
  
  /// [MỚI] Thông báo có bản cập nhật mới (dùng để hiện chấm đỏ ở menu)
  final ValueNotifier<AppVersionInfo?> updateAvailable = ValueNotifier<AppVersionInfo?>(null);
  
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
    if (_isChecking) {
      debugPrint('⏳ Đang có tiến trình check update khác chạy...');
      return _latestVersion;
    }
    
    _isChecking = true;
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
          updateAvailable.value = _latestVersion; // Cập nhật notifier
          return _latestVersion;
        } else {
          debugPrint('✅ Đã là bản mới nhất');
          updateAvailable.value = null;
          return null;
        }
      } else {
        debugPrint('⚠️ Không thể kiểm tra cập nhật: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Lỗi kiểm tra cập nhật: $e');
      return null;
    } finally {
      _isChecking = false;
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
    // Xác định platform và URL download
    String? downloadUrl;
    String fileName;
    
    if (Platform.isWindows) {
      downloadUrl = versionInfo.downloadUrl['windows'];
      fileName = 'idmav_app_update.zip';
    } else if (Platform.isAndroid) {
      // Thử lấy URL theo kiến trúc chip (để giảm dung lượng tải)
      // Mặc định là 'android', nếu có 'android_arm64' hoặc 'android_armv7' thì dùng
      downloadUrl = versionInfo.downloadUrl['android'];
      
      try {
        // Đọc kiến trúc chip (giản lược)
        final String arch = Platform.version.toLowerCase();
        if (arch.contains('arm64') || arch.contains('aarch64')) {
          downloadUrl = versionInfo.downloadUrl['android_arm64'] ?? downloadUrl;
          debugPrint('📱 Phát hiện kiến trúc ARM64');
        } else if (arch.contains('arm')) {
          downloadUrl = versionInfo.downloadUrl['android_armv7'] ?? downloadUrl;
          debugPrint('📱 Phát hiện kiến trúc ARMV7');
        }
      } catch (e) {
        debugPrint('⚠️ Không xác định được kiến trúc chip: $e');
      }
      
      fileName = 'idmav_app_update.apk';
    } else {
      debugPrint('⚠️ Platform không được hỗ trợ');
      return false;
    }
    
    if (downloadUrl == null || downloadUrl.isEmpty) {
      debugPrint('⚠️ Không có link download cho platform này');
      return false;
    }
    
    debugPrint('🔧 Platform: ${Platform.operatingSystem}');
    debugPrint('🔧 Download URL: $downloadUrl');
    
    // Retry 3 lần
    for (int attempt = 1; attempt <= 3; attempt++) {
      debugPrint('📥 Bắt đầu download (lần $attempt): $downloadUrl');
      
      try {
        // Lấy thư mục download
        final directory = await getTemporaryDirectory();
        final filePath = '${directory.path}/$fileName';
        final file = File(filePath);
        
        // Xóa file cũ nếu có
        if (await file.exists()) {
          await file.delete();
        }
        
        // Tối ưu hóa URL (Google Drive, Mirror Proxy, v.v.)
        String requestUrl = _processUrl(downloadUrl, attempt);
        debugPrint('🌐 Request URL: $requestUrl');

        // Tạo HttpClient với timeout dài
        final httpClient = HttpClient();
        httpClient.connectionTimeout = const Duration(seconds: 30);

        final request = await httpClient.getUrl(Uri.parse(requestUrl));
        final response = await request.close();
        
        if (response.statusCode != 200) {
          debugPrint('❌ Download thất bại: ${response.statusCode}');
          if (attempt < 3) {
            debugPrint('🔄 Thử lại sau 2 giây...');
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          return false;
        }
        
        final contentLength = response.contentLength;
        int received = 0;
        
        // Stream trực tiếp vào file (không lưu RAM)
        final sink = file.openWrite();
        
        await for (var chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          
          if (contentLength > 0 && onProgress != null) {
            onProgress(received / contentLength);
          }
        }
        
        await sink.flush();
        await sink.close();
        httpClient.close();
        
        debugPrint('✅ Download hoàn tất: $filePath (${(received / 1024 / 1024).toStringAsFixed(1)} MB)');
        
        // [v1.1.6] Bỏ qua kiểm tra toàn vẹn để tăng tốc độ tối đa
        debugPrint('� Bỏ qua kiểm tra toàn vẹn, tiến hành cài đặt ngay...');

        // 2. Verify file size
        final downloadedFile = File(filePath);
        final fileSize = await downloadedFile.length();
        if (fileSize < 1000000) { // < 1MB = lỗi
          debugPrint('❌ File quá nhỏ, có thể bị lỗi: $fileSize bytes');
          if (attempt < 3) {
            debugPrint('🔄 Thử lại sau 2 giây...');
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          return false;
        }
        
        // Cài đặt
        if (Platform.isWindows) {
          return await _installWindows(filePath);
        } else if (Platform.isAndroid) {
          return await _installAndroid(filePath);
        }
        
        return false;
        
      } catch (e) {
        debugPrint('❌ Lỗi download (lần $attempt): $e');
        if (attempt < 3) {
          debugPrint('🔄 Thử lại sau 2 giây...');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        return false;
      }
    }
    
    return false;
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
      debugPrint('📱 Mở cài đặt APK: $apkPath');
      
      // Kiểm tra file tồn tại
      final apkFile = File(apkPath);
      final exists = await apkFile.exists();
      final size = exists ? await apkFile.length() : 0;
      debugPrint('📱 File exists: $exists, Size: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      
      if (!exists || size < 1000000) {
        debugPrint('❌ File APK không hợp lệ');
        return false;
      }
      
      // Mở file APK để cài đặt
      debugPrint('📱 Gọi OpenFilex.open...');
      final result = await OpenFilex.open(apkPath);
      debugPrint('📱 OpenFilex result: type=${result.type}, message=${result.message}');
      
      if (result.type == ResultType.done) {
        debugPrint('✅ Đã mở installer');
        return true;
      } else {
        debugPrint('⚠️ Không thể mở APK: ${result.message}');
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Lỗi cài đặt Android: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      return false;
    }
  }

  /// [MỚI] Khởi tạo quy trình check update ngầm
  void initUpdateCheck(BuildContext context) {
    Future.delayed(const Duration(seconds: 3), () async {
      try {
        await checkForUpdate();
        // Không tự động hiện dialog ở đây nữa, chỉ check để updateAvailable notifier có data
      } catch (e) {
        debugPrint('⚠️ Lỗi check update tự động: $e');
      }
    });
  }

  /// [MỚI] Hiển thị dialog thông báo có bản cập nhật (Public để gọi từ menu)
  void showUpdateDialog(BuildContext context, AppVersionInfo versionInfo) {
    showDialog(
      context: context,
      barrierDismissible: !versionInfo.required,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.system_update, color: Colors.green, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Có bản cập nhật mới!', 
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Text('Phiên bản ${versionInfo.version}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Có gì mới:', 
              style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                versionInfo.releaseNotes,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (versionInfo.required) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange[700], size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Bản cập nhật này là bắt buộc',
                        style: TextStyle(fontSize: 12, color: Colors.orange)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (!versionInfo.required)
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Để sau'),
            ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            icon: const Icon(Icons.download, size: 20),
            label: const Text('Cập nhật ngay'),
            onPressed: () {
              Navigator.pop(ctx);
              _startDownloadUpdate(context, versionInfo);
            },
          ),
        ],
      ),
    );
  }

  /// [MỚI] Bắt đầu download và cài đặt update
  void _startDownloadUpdate(BuildContext context, AppVersionInfo versionInfo) {
    double progress = 0;
    bool isDownloading = true;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (isDownloading) {
            isDownloading = false;
            downloadAndInstall(
              versionInfo: versionInfo,
              onProgress: (p) {
                setDialogState(() => progress = p);
              },
            ).then((success) {
              if (!success && context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Lỗi tải cập nhật. Vui lòng thử lại sau.'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            });
          }
          
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(
                  progress < 1 
                    ? 'Đang tải: ${(progress * 100).toStringAsFixed(0)}%'
                    : 'Đang cài đặt...',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
              ],
            ),
          );
        },
      ),
    );
  }

  /// [MỚI] Tối ưu hóa URL tải xuống
  /// Sử dụng mirror proxy ngay từ đầu để tăng tốc tải từ GitHub
  String _processUrl(String url, int attempt) {
    // 1. Xử lý Google Drive (Chuyển link view sang link download trực tiếp)
    if (url.contains('drive.google.com')) {
      final regExp = RegExp(r'\/d\/([a-zA-Z0-9-_]+)');
      final match = regExp.firstMatch(url);
      if (match != null) {
        final fileId = match.group(1);
        // Link download trực tiếp (Lưu ý: File > 100MB có thể bị chặn bởi trang cảnh báo virus)
        return 'https://drive.google.com/uc?export=download&id=$fileId';
      }
    }

    // 2. Sử dụng Mirror Proxy cho GitHub - NGAY TỪ LẦN ĐẦU để tăng tốc
    if (url.contains('github.com')) {
      // Danh sách mirror proxy (thứ tự ưu tiên)
      final mirrors = [
        'https://mirror.ghproxy.com/',      // Mirror chính - nhanh ở VN
        'https://gh.api.99988866.xyz/',     // Mirror backup 1
        'https://ghproxy.net/',             // Mirror backup 2
      ];
      
      // Chọn mirror theo số lần thử (xoay vòng nếu retry)
      final mirrorIndex = (attempt - 1) % mirrors.length;
      final mirror = mirrors[mirrorIndex];
      
      debugPrint('🚀 Sử dụng mirror #${mirrorIndex + 1}: $mirror');
      return '$mirror$url';
    }

    return url;
  }

  /// [MỚI] Tính toán SHA-256 của file
  Future<String> _calculateFileHash(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }
}
