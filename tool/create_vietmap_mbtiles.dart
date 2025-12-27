import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:collection';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

// --- CẤU HÌNH VIETMAP ---
const int minZoom = 6;
const int maxZoom = 12;
const int maxThreads = 5; // Giảm xuống 5 thread để tránh bị block
const String outputFileName = 'assets/vietnam_vietmap.mbtiles';
const String userAgent = 'iDMAV_Mobile_App/1.0';

// VietMap Tilemap API Key
const String vietmapApiKey = 'dd90b70f3100c8b3cf5f0e0818b323492f7e15f9697ab44b';

// Bounds: Việt Nam + Biển Đông
const double minLat = 6.0;
const double maxLat = 23.5;
const double minLon = 102.0;
const double maxLon = 118.0;

// Rate limiting - delay giữa các request (ms)
const int requestDelayMs = 200; // 200ms delay để tránh bị block

class Tile {
  final int z;
  final int x;
  final int y;
  Tile(this.z, this.x, this.y);
}

// Global counters
int downloaded = 0;
int failed = 0;
int totalTiles = 0;

void main() async {
  try {
    print('🗺️  Bắt đầu tạo bản đồ VIETMAP Offline cho iDMAV...');
    print('Zoom: $minZoom - $maxZoom');
    print('Bounds: $minLat, $minLon -> $maxLat, $maxLon');
    print('Threads: $maxThreads');
    print('API Key: ${vietmapApiKey.substring(0, 10)}...');
    
    final file = File(outputFileName);
    if (file.existsSync()) {
      print('⚠️  File $outputFileName đã tồn tại. Đang xóa...');
      try {
        file.deleteSync();
      } catch (e) {
        print('❌  Không thể xóa file cũ: $e');
        return;
      }
    } else {
      Directory('assets').createSync(recursive: true);
    }

    final db = sqlite3.open(outputFileName);
    
    // Tối ưu SQLite
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    
    // 1. Tạo Tables
    print('📦  Đang tạo cấu trúc database...');
    db.execute('''
      CREATE TABLE metadata (name text, value text);
      CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob);
      CREATE UNIQUE INDEX tile_index on tiles (zoom_level, tile_column, tile_row);
    ''');

    // 2. Insert Metadata
    final stmt = db.prepare('INSERT INTO metadata (name, value) VALUES (?, ?)');
    stmt.execute(['name', 'VietMap Vietnam']);
    stmt.execute(['type', 'overlay']);
    stmt.execute(['version', '1']);
    stmt.execute(['description', 'VietMap Offline (Zoom $minZoom-$maxZoom)']);
    stmt.execute(['format', 'png']);
    stmt.execute(['bounds', '$minLon,$minLat,$maxLon,$maxLat']);
    stmt.dispose();

    // 3. Generate Tile List
    print('🔄  Đang tính toán danh sách tiles...');
    List<Tile> allTiles = [];
    for (int z = minZoom; z <= maxZoom; z++) {
      var p1 = _latLngToTile(minLat, minLon, z);
      var p2 = _latLngToTile(maxLat, maxLon, z);
      int x1 = min(p1.x, p2.x);
      int x2 = max(p1.x, p2.x);
      int y1 = min(p1.y, p2.y);
      int y2 = max(p1.y, p2.y);
      
      for (int x = x1; x <= x2; x++) {
        for (int y = y1; y <= y2; y++) {
          allTiles.add(Tile(z, x, y));
        }
      }
    }

    totalTiles = allTiles.length;
    print('🚀  Tổng số tiles cần tải: $totalTiles');
    print('⏱️  Thời gian ước tính: ${(totalTiles * requestDelayMs / 1000 / 60 / maxThreads).toStringAsFixed(1)} phút');

    // 4. Download Parallel using Queue
    final insertTile = db.prepare('INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)');
    final client = http.Client();
    
    final queue = Queue<Tile>.from(allTiles);
    List<Future> workers = [];

    // Start workers
    for (int i = 0; i < maxThreads; i++) {
      workers.add(_worker(queue, client, insertTile, i));
    }

    // Wait for all workers to finish
    await Future.wait(workers);
    
    insertTile.dispose();
    db.dispose();
    client.close();

    print('\n✅  HOÀN TẤT!');
    print('📁  File: $outputFileName');
    print('📊  Đã tải: $downloaded, Lỗi: $failed');
    print('💡  Copy file này vào assets và cập nhật OfflineMapService để dùng VietMap offline.');
  } catch (e, stack) {
    print('\n❌  CRITICAL ERROR: $e');
    print(stack);
  }
}

Future<void> _worker(Queue<Tile> queue, http.Client client, PreparedStatement insertTile, int workerId) async {
  while (queue.isNotEmpty) {
    // Lấy tile tiếp theo từ queue
    final tile = queue.removeFirst();
    
    try {
      // VietMap Tile URL - sử dụng @2x cho tiles chất lượng cao
      final url = Uri.parse(
        'https://maps.vietmap.vn/api/tm/${tile.z}/${tile.x}/${tile.y}@2x.png?apikey=$vietmapApiKey'
      );
      
      final response = await client.get(url, headers: {
        'User-Agent': userAgent,
        'Referer': 'https://maps.vietmap.vn/',
      });

      if (response.statusCode == 200) {
        // MBTiles TMS conversion
        int tmsY = (1 << tile.z) - 1 - tile.y;
        
        // SQLite execute is synchronous
        insertTile.execute([tile.z, tile.x, tmsY, response.bodyBytes]);
        downloaded++;
      } else if (response.statusCode == 429 || response.statusCode == 423) {
        // Rate limited - đưa lại vào queue và chờ lâu hơn
        queue.add(tile);
        await Future.delayed(Duration(milliseconds: 1000)); // Chờ 1 giây
        print('\n⚠️  Rate limited (${response.statusCode}), đang chờ...');
      } else {
        failed++;
        // Ghi log lỗi cho tiles đầu tiên
        if (failed <= 5) {
          print('\n❌  Tile z${tile.z}/${tile.x}/${tile.y} failed: ${response.statusCode}');
        }
      }
    } catch (e) {
      failed++;
    }

    // Rate limiting delay
    await Future.delayed(Duration(milliseconds: requestDelayMs));

    if ((downloaded + failed) % 100 == 0) {
       double percent = (downloaded + failed) / totalTiles * 100;
       stdout.write('\r⏳  Tiến độ: ${percent.toStringAsFixed(1)}% (${downloaded + failed}/$totalTiles) [OK: $downloaded, Err: $failed]   ');
    }
  }
}

Point<int> _latLngToTile(double lat, double lon, int zoom) {
  int n = 1 << zoom; // 2^zoom
  int x = ((lon + 180.0) / 360.0 * n).floor();
  double latRad = lat * pi / 180.0;
  int y = ((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / pi) / 2.0 * n).floor();
  return Point(x, y);
}
