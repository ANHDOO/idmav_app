// Script để lọc maritime từ vn_boundaries.json
// Chạy: dart run tools/filter_maritime_boundaries.dart

import 'dart:convert';
import 'dart:io';

// Kiểm tra polygon có phải maritime (trên biển) không
bool _isPolygonMaritime(List<List<double>> ring) {
  if (ring.isEmpty) return false;
  
  double sumLng = 0;
  int seaCount = 0;
  
  for (var coord in ring) {
    double lng = coord[0];
    sumLng += lng;
    
    // Kinh độ > 109.5 = ngoài bờ biển VN = trên biển
    if (lng > 109.5) seaCount++;
  }
  
  double centerLng = sumLng / ring.length;
  
  // Centroid ngoài bờ biển hoặc >50% điểm trên biển -> maritime
  return centerLng > 109.5 || seaCount > ring.length * 0.5;
}

List<List<double>> _extractRing(dynamic ringData) {
  List<List<double>> result = [];
  if (ringData is List) {
    for (var coord in ringData) {
      if (coord is List && coord.length >= 2) {
        result.add([(coord[0] as num).toDouble(), (coord[1] as num).toDouble()]);
      }
    }
  }
  return result;
}

Future<void> main() async {
  print('🚀 Lọc maritime từ vn_boundaries.json...');
  
  String inputPath = 'assets/boundaries/vn_boundaries.json';
  File inputFile = File(inputPath);
  
  if (!await inputFile.exists()) {
    print('❌ Không tìm thấy file $inputPath');
    return;
  }
  
  String jsonString = await inputFile.readAsString();
  Map<String, dynamic> data = jsonDecode(jsonString);
  List<dynamic> features = data['features'] ?? [];
  
  print('📖 Đọc ${features.length} features');
  
  List<Map<String, dynamic>> filteredFeatures = [];
  int totalMaritimeSkipped = 0;
  
  for (var feature in features) {
    String name = feature['name'] ?? '';
    
    Map<String, dynamic>? geometry = feature['geometry'];
    List<List<List<List<double>>>> filteredPolygons = [];
    int maritimeSkipped = 0;
    
    if (geometry != null) {
      String geoType = geometry['type'] ?? '';
      List<dynamic> coords = geometry['coordinates'] ?? [];
      
      if (geoType == 'Polygon') {
        List<List<List<double>>> rings = [];
        for (var ringData in coords) {
          var ring = _extractRing(ringData);
          if (ring.isNotEmpty && !_isPolygonMaritime(ring)) {
            rings.add(ring);
          } else if (ring.isNotEmpty) {
            maritimeSkipped++;
          }
        }
        if (rings.isNotEmpty) {
          filteredPolygons.add(rings);
        }
      } else if (geoType == 'MultiPolygon') {
        for (var polygon in coords) {
          List<List<List<double>>> rings = [];
          for (var ringData in polygon) {
            var ring = _extractRing(ringData);
            if (ring.isNotEmpty && !_isPolygonMaritime(ring)) {
              rings.add(ring);
            } else if (ring.isNotEmpty) {
              maritimeSkipped++;
            }
          }
          if (rings.isNotEmpty) {
            filteredPolygons.add(rings);
          }
        }
      }
    }
    
    if (filteredPolygons.isNotEmpty) {
      filteredFeatures.add({
        ...feature,
        'geometry': {
          'type': 'MultiPolygon',
          'coordinates': filteredPolygons,
        },
      });
      
      if (maritimeSkipped > 0) {
        print('  🌊 $name: bỏ $maritimeSkipped polygon biển');
      }
    }
    
    totalMaritimeSkipped += maritimeSkipped;
  }
  
  // Tạo output
  Map<String, dynamic> output = {
    ...data,
    'note': 'Đã lọc biển (maritime)',
    'features': filteredFeatures,
  };
  
  // Lưu file (ghi đè)
  String outputJson = JsonEncoder.withIndent('  ').convert(output);
  await inputFile.writeAsString(outputJson);
  
  int fileSizeKB = (await inputFile.length()) ~/ 1024;
  print('\n✅ Hoàn thành!');
  print('📁 File: $inputPath');
  print('📊 Kích thước: ${fileSizeKB} KB');
  print('🌊 Tổng polygon biển đã lọc: $totalMaritimeSkipped');
}
