// Script tải dữ liệu đường Việt Nam chi tiết (Full High Detail)
// Bao gồm: Cao tốc, Quốc lộ, Tỉnh lộ, Đường huyện, Đường dân sinh...
// Loại bỏ: Đường dẫn (link), đường nhánh (spur) để giảm rác.
// Sử dụng kỹ thuật Chia lưới (Grid Splitting) để tránh timeout với dữ liệu lớn.
//
// Cách chạy: dart run tools/download_vn_roads.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// --- CẤU HÌNH ---
const String outputFile = 'assets/roads/vn_roads.json';
const double minLat = 8.0;
const double minLon = 102.0;
const double maxLat = 24.0;
const double maxLon = 110.0;
const double gridSize = 1; // Kích thước ô lưới (độ)
const int maxConcurrentRequests = 10; // Số lượng request song song

// Các loại đường cần tải (thêm secondary để đầy đủ hơn)
const List<String> roadTypes = [
  'motorway', 'trunk', 'primary', 'secondary'
];
final String roadTypesRegex = roadTypes.join('|');

// Sử dụng các server giống như online search (maps.mail.ru nhanh nhất)
const List<String> overpassServers = [
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass-api.de/api/interpreter',
  'https://overpass.openstreetmap.ru/api/interpreter',
];

// --- LOGIC ---

Future<void> main() async {
  print('🚀 Bắt đầu tải dữ liệu đường Việt Nam (FULL DETAIL)...');
  
  // 1. Tạo danh sách các ô lưới (Tiles)
  List<List<double>> tiles = [];
  for (double lat = minLat; lat < maxLat; lat += gridSize) {
    for (double lon = minLon; lon < maxLon; lon += gridSize) {
      tiles.add([lat, lon, lat + gridSize, lon + gridSize]);
    }
  }
  print('📦 Tổng số ô lưới cần tải: ${tiles.length}');

  // 2. Tải dữ liệu song song
  Map<String, List<List<List<double>>>> mergedRoads = {}; // key: "ref|name|type" -> segments
  
  int completed = 0;
  int successCount = 0;
  final stopwatch = Stopwatch()..start();
  
  // Xử lý theo lô (batch) để giới hạn concurrency
  for (int i = 0; i < tiles.length; i += maxConcurrentRequests) {
    int end = (i + maxConcurrentRequests < tiles.length) ? i + maxConcurrentRequests : tiles.length;
    var batch = tiles.sublist(i, end);
    
    await Future.wait(batch.map((tile) async {
      var result = await _fetchTile(tile);
      completed++;
      
      if (result != null && result.isNotEmpty) {
        successCount++;
        _mergeData(mergedRoads, result);
        stdout.write('\r✅ Tiến độ: $completed/${tiles.length} | Đã tìm thấy: ${mergedRoads.length} tuyến đường...');
      } else {
        stdout.write('\r⏳ Tiến độ: $completed/${tiles.length}...');
      }
    }));
  }
  
  print('\n\n✨ Đã tải xong! Đang xử lý và lưu file...');
  
  // 3. Convert sang GeoJSON features format của App
  List<Map<String, dynamic>> features = [];
  
  mergedRoads.forEach((key, segments) {
    var parts = key.split('||');
    String name = parts[1];
    String ref = parts[0];
    String type = parts[2];
    
    // Tính bbox toàn bộ tuyến đường
    double rMinLat = 90, rMaxLat = -90, rMinLon = 180, rMaxLon = -180;
    for (var seg in segments) {
      for (var pt in seg) {
        if (pt[1] < rMinLat) rMinLat = pt[1];
        if (pt[1] > rMaxLat) rMaxLat = pt[1];
        if (pt[0] < rMinLon) rMinLon = pt[0];
        if (pt[0] > rMaxLon) rMaxLon = pt[0];
      }
    }
    
    features.add({
      'name': name,
      'ref': ref,
      'road_type': type,
      'bbox': [rMinLat, rMinLon, rMaxLat, rMaxLon],
      'geometry': {
        'type': 'MultiLineString',
        'coordinates': segments,
      }
    });
  });
  
  // Sắp xếp
  features.sort((a, b) => (a['ref'] as String).compareTo(b['ref'] as String));

  final output = {
    'version': '1.0',
    'generated': DateTime.now().toIso8601String().split('T')[0],
    'source': 'OpenStreetMap Overpass (Dart Script)',
    'total': features.length,
    'features': features,
  };
  
  final file = File(outputFile);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(output));
  
  print('💾 Đã lưu vào: ${file.path}');
  print('� Dung lượng: ${(await file.length()) / 1024 / 1024} MB');
  print('⏱️ Thời gian: ${stopwatch.elapsed.inMinutes} phút');
}

Future<Map<String, List<List<List<double>>>>?> _fetchTile(List<double> tile) async {
  double lat1 = tile[0], lon1 = tile[1], lat2 = tile[2], lon2 = tile[3];
  String bbox = '$lat1,$lon1,$lat2,$lon2';
  
  // Query: Lọc theo Area VN VÀ Bbox
  // Thêm query cho đường có mã số (ref) để bắt tất cả QL, TL, ĐT...
  String query = '''
    [out:json][timeout:90];
    area["ISO3166-1"="VN"]->.searchArea;
    (
      way["highway"~"^($roadTypesRegex)\$"](area.searchArea)($bbox);
      way["highway"]["ref"](area.searchArea)($bbox);
    );
    out geom;
  ''';

  for (int attempt = 0; attempt < 3; attempt++) {
    // Round robin server
    String server = overpassServers[(lat1.toInt() + attempt) % overpassServers.length];
    
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      final req = await client.postUrl(Uri.parse(server));
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      req.write('data=${Uri.encodeComponent(query)}');
      
      final resp = await req.close().timeout(const Duration(seconds: 90));
      
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        return _parseElements(json['elements']);
      } else if (resp.statusCode == 429) {
        await Future.delayed(const Duration(seconds: 5)); // Chờ và retry
        continue;
      }
    } catch (e) {
      // Ignore error and retry
    }
  }
  return null;
}

Map<String, List<List<List<double>>>> _parseElements(List<dynamic>? elements) {
  if (elements == null) return {};
  Map<String, List<List<List<double>>>> tileRoads = {};
  
  for (var el in elements) {
    if (el['type'] != 'way') continue;
    var tags = el['tags'] ?? {};
    var geom = el['geometry'];
    if (geom == null) continue;
    
    String name = tags['name'] ?? '';
    String ref = tags['ref'] ?? '';
    String type = tags['highway'] ?? '';
    
    // Chỉ lấy đường có tên HOẶC có ref
    if (name.isEmpty && ref.isEmpty) continue;
    
    // Key định danh (gộp các đoạn cùng tên/ref)
    String key = '$ref||$name||$type';
    
    List<List<double>> coords = [];
    for (var pt in geom) {
      coords.add([(pt['lon'] as num).toDouble(), (pt['lat'] as num).toDouble()]);
    }
    
    if (!tileRoads.containsKey(key)) tileRoads[key] = [];
    tileRoads[key]!.add(coords);
  }
  return tileRoads;
}

void _mergeData(Map<String, List<List<List<double>>>> main, Map<String, List<List<List<double>>>> chunk) {
  chunk.forEach((key, segments) {
    if (!main.containsKey(key)) main[key] = [];
    main[key]!.addAll(segments);
  });
}
