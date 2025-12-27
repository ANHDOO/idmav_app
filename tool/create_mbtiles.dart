import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:collection';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

// --- CẤU HÌNH ---
const int minZoom = 6;
const int maxZoom = 12;
const int maxThreads = 50; // Tăng lại lên 50 vì Queue rất nhẹ
const String outputFileName = 'assets/vietnam_map.mbtiles';
const String userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36';

// Bounds: VN + Biển Đông
const double minLat = 6.0;
const double maxLat = 23.5;
const double minLon = 102.0;
const double maxLon = 118.0;

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
    print('🗺️  Bắt đầu tạo bản đồ Offline cho iDMAV (Multi-threaded Queue)...');
    print('Zoom: $minZoom - $maxZoom');
    print('Bounds: $minLat, $minLon -> $maxLat, $maxLon');
    print('Threads: $maxThreads');
    
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
    stmt.execute(['name', 'Vietnam Map']);
    stmt.execute(['type', 'overlay']);
    stmt.execute(['version', '1']);
    stmt.execute(['description', 'iDMAV Offline Map (Zoom $minZoom-$maxZoom)']);
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

    // 4. Download Parallel using Queue
    final insertTile = db.prepare('INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)');
    final client = http.Client();
    
    final queue = Queue<Tile>.from(allTiles);
    List<Future> workers = [];

    // Start workers
    for (int i = 0; i < maxThreads; i++) {
      workers.add(_worker(queue, client, insertTile));
    }

    // Wait for all workers to finish
    await Future.wait(workers);
    
    insertTile.dispose();
    db.dispose();
    client.close();

    print('\n✅  HOÀN TẤT!');
    print('📁  File: $outputFileName');
    print('📊  Đã tải: $downloaded, Lỗi: $failed');
  } catch (e, stack) {
    print('\n❌  CRITICAL ERROR: $e');
    print(stack);
  }
}

Future<void> _worker(Queue<Tile> queue, http.Client client, PreparedStatement insertTile) async {
  while (queue.isNotEmpty) {
    // Lấy tile tiếp theo từ queue (đồng bộ, an toàn trong Dart single-isolate)
    final tile = queue.removeFirst();
    
    try {
      final url = Uri.parse('https://mt1.google.com/vt/lyrs=m&x=${tile.x}&y=${tile.y}&z=${tile.z}');
      final response = await client.get(url, headers: {'User-Agent': userAgent});

      if (response.statusCode == 200) {
        // MBTiles TMS conversion
        int tmsY = (1 << tile.z) - 1 - tile.y;
        
        // SQLite execute is synchronous
        insertTile.execute([tile.z, tile.x, tmsY, response.bodyBytes]);
        downloaded++;
      } else {
        failed++;
      }
    } catch (e) {
      failed++;
    }

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
