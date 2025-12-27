// Script để tạo file vn_boundaries_2025.json (34 đơn vị hành chính sau sáp nhập)
// Chạy: dart run tools/generate_boundaries_2025.dart
// 
// Đọc vn_boundaries.json (63 tỉnh) và merge theo Nghị quyết 202/2025/QH15
// CHỈ GIỮ OUTER BOUNDARY (đường viền ngoài cùng), loại bỏ biên trong và biển

import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Mapping: Tên đơn vị mới -> Danh sách tỉnh cũ được gộp
// Theo Nghị quyết 202/2025/QH15: 11 giữ nguyên + 23 sáp nhập = 34 đơn vị
const Map<String, List<String>> mergeMapping = {
  // === I. 11 ĐƠN VỊ GIỮ NGUYÊN ===
  'Thành phố Hà Nội': ['Hà Nội'],
  'Thành phố Huế': ['Thừa Thiên Huế'],
  'Lai Châu': ['Lai Châu'],
  'Điện Biên': ['Điện Biên'],
  'Sơn La': ['Sơn La'],
  'Lạng Sơn': ['Lạng Sơn'],
  'Quảng Ninh': ['Quảng Ninh'],
  'Thanh Hóa': ['Thanh Hóa'],
  'Nghệ An': ['Nghệ An'],
  'Hà Tĩnh': ['Hà Tĩnh'],
  'Cao Bằng': ['Cao Bằng'],
  
  // === II. 23 ĐƠN VỊ MỚI SAU SÁP NHẬP ===
  // 1-6: Miền Bắc
  'Tuyên Quang': ['Hà Giang', 'Tuyên Quang'],
  'Lào Cai': ['Lào Cai', 'Yên Bái'],
  'Thái Nguyên': ['Bắc Kạn', 'Thái Nguyên'],
  'Phú Thọ': ['Vĩnh Phúc', 'Phú Thọ', 'Hòa Bình'],
  'Bắc Ninh': ['Bắc Ninh', 'Bắc Giang'],
  'Hưng Yên': ['Hưng Yên', 'Thái Bình'],
  
  // 7-8: Thành phố và Đồng bằng sông Hồng
  'Thành phố Hải Phòng': ['Hải Phòng', 'Hải Dương'],
  'Ninh Bình': ['Hà Nam', 'Nam Định', 'Ninh Bình'],
  
  // 9-15: Miền Trung & Tây Nguyên
  'Quảng Trị': ['Quảng Bình', 'Quảng Trị'],
  'Thành phố Đà Nẵng': ['Đà Nẵng', 'Quảng Nam'],
  'Quảng Ngãi': ['Kon Tum', 'Quảng Ngãi'],
  'Gia Lai': ['Gia Lai', 'Bình Định'],
  'Khánh Hòa': ['Khánh Hòa', 'Ninh Thuận'],
  'Lâm Đồng': ['Lâm Đồng', 'Đắk Nông', 'Bình Thuận'],
  'Đắk Lắk': ['Đắk Lắk', 'Phú Yên'],
  
  // 16-18: Đông Nam Bộ
  'Thành phố Hồ Chí Minh': ['Hồ Chí Minh', 'Bình Dương', 'Bà Rịa - Vũng Tàu'],
  'Đồng Nai': ['Đồng Nai', 'Bình Phước'],
  'Tây Ninh': ['Tây Ninh', 'Long An'],
  
  // 19-23: Tây Nam Bộ (Đồng bằng sông Cửu Long)
  'Thành phố Cần Thơ': ['Cần Thơ', 'Sóc Trăng', 'Hậu Giang'],
  'Vĩnh Long': ['Vĩnh Long', 'Bến Tre', 'Trà Vinh'],
  'Đồng Tháp': ['Đồng Tháp', 'Tiền Giang'],
  'Cà Mau': ['Cà Mau', 'Bạc Liêu'],
  'An Giang': ['An Giang', 'Kiên Giang'],
};

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

// Tính diện tích polygon (để tìm polygon lớn nhất)
double _polygonArea(List<List<double>> ring) {
  double area = 0;
  int n = ring.length;
  for (int i = 0; i < n; i++) {
    int j = (i + 1) % n;
    area += ring[i][0] * ring[j][1];
    area -= ring[j][0] * ring[i][1];
  }
  return area.abs() / 2;
}

Future<void> main() async {
  print('🚀 Bắt đầu tạo dữ liệu 34 tỉnh 2025...');
  print('📌 Chế độ: CHỈ GIỮ OUTER BOUNDARY + LỌC BIỂN');
  
  // 1. Đọc file 63 tỉnh hiện tại
  String inputPath = 'assets/boundaries/vn_boundaries.json';
  File inputFile = File(inputPath);
  
  if (!await inputFile.exists()) {
    print('❌ Không tìm thấy file $inputPath');
    print('   Vui lòng chạy generate_boundaries.dart trước!');
    return;
  }
  
  String jsonString = await inputFile.readAsString();
  Map<String, dynamic> oldData = jsonDecode(jsonString);
  List<dynamic> oldFeatures = oldData['features'] ?? [];
  
  print('📖 Đọc ${oldFeatures.length} tỉnh từ file cũ');
  
  // 2. Tạo map để lookup nhanh theo tên
  Map<String, Map<String, dynamic>> provinceMap = {};
  for (var feature in oldFeatures) {
    String name = feature['name'] ?? '';
    provinceMap[name] = feature;
  }
  
  // 3. Merge các tỉnh theo mapping
  List<Map<String, dynamic>> newFeatures = [];
  int mergedCount = 0;
  int skippedCount = 0;
  int maritimeSkipped = 0;
  
  for (var entry in mergeMapping.entries) {
    String newName = entry.key;
    List<String> oldNames = entry.value;
    
    // Lấy geometry từ các tỉnh cũ
    List<Map<String, dynamic>> foundProvinces = [];
    List<String> notFound = [];
    
    for (var oldName in oldNames) {
      // Tìm kiếm linh hoạt (partial match)
      var found = provinceMap.entries.where((e) => 
        e.key.contains(oldName) || oldName.contains(e.key)
      ).map((e) => e.value).toList();
      
      if (found.isNotEmpty) {
        foundProvinces.add(found.first);
      } else {
        notFound.add(oldName);
      }
    }
    
    if (foundProvinces.isEmpty) {
      print('⚠️ Không tìm thấy dữ liệu cho: $newName (cần: ${oldNames.join(", ")})');
      skippedCount++;
      continue;
    }
    
    if (notFound.isNotEmpty) {
      print('⚠️ $newName: Thiếu ${notFound.join(", ")}');
    }
    
    // Merge geometry - CHỈ GIỮ OUTER BOUNDARY
    var result = _mergeProvincesOuterOnly(newName, foundProvinces);
    maritimeSkipped += result['maritime_skipped'] as int;
    newFeatures.add(result['feature'] as Map<String, dynamic>);
    mergedCount++;
    
    print('✅ $newName (gộp ${foundProvinces.length} tỉnh, bỏ ${result['maritime_skipped']} biển)');
  }
  
  // 4. Xử lý biên giới quốc gia - cũng lọc biển
  var vietnamBorder = provinceMap['Việt Nam'];
  if (vietnamBorder != null) {
    var result = _filterMaritimeFromFeature(vietnamBorder);
    newFeatures.insert(0, result['feature'] as Map<String, dynamic>);
    print('✅ Việt Nam (biên giới quốc gia, bỏ ${result['maritime_skipped']} biển)');
  }
  
  // 5. Tạo output
  Map<String, dynamic> output = {
    'version': '2.1',
    'generated': DateTime.now().toIso8601String().split('T')[0],
    'source': 'Merged from Nominatim data based on 2025 reform plan',
    'note': '34 đơn vị hành chính - CHỈ OUTER BOUNDARY, đã lọc biển',
    'total': newFeatures.length,
    'features': newFeatures,
  };
  
  // 6. Lưu file
  String outputPath = 'assets/boundaries/vn_boundaries_2025.json';
  File outputFile = File(outputPath);
  
  String outputJson = JsonEncoder.withIndent('  ').convert(output);
  await outputFile.writeAsString(outputJson);
  
  int fileSizeKB = (await outputFile.length()) ~/ 1024;
  print('\n✅ Hoàn thành!');
  print('📁 File: $outputPath');
  print('📊 Kích thước: ${fileSizeKB} KB');
  print('📝 Số đơn vị: ${newFeatures.length} (merged: $mergedCount, skipped: $skippedCount)');
  print('🌊 Tổng polygon biển đã lọc: $maritimeSkipped');
}

Map<String, dynamic> _filterMaritimeFromFeature(Map<String, dynamic> feature) {
  int maritimeSkipped = 0;
  
  Map<String, dynamic>? geometry = feature['geometry'];
  List<List<List<List<double>>>> filteredPolygons = [];
  
  if (geometry != null) {
    String geoType = geometry['type'] ?? '';
    List<dynamic> coords = geometry['coordinates'] ?? [];
    
    if (geoType == 'Polygon') {
      var ring = _extractRing(coords[0]);
      if (!_isPolygonMaritime(ring)) {
        filteredPolygons.add([ring]);
      } else {
        maritimeSkipped++;
      }
    } else if (geoType == 'MultiPolygon') {
      for (var polygon in coords) {
        List<List<List<double>>> rings = [];
        for (var ring in polygon) {
          var extracted = _extractRing(ring);
          if (!_isPolygonMaritime(extracted)) {
            rings.add(extracted);
          } else {
            maritimeSkipped++;
          }
        }
        if (rings.isNotEmpty) {
          filteredPolygons.add(rings);
        }
      }
    }
  }
  
  return {
    'feature': {
      ...feature,
      'geometry': {
        'type': 'MultiPolygon',
        'coordinates': filteredPolygons,
      },
    },
    'maritime_skipped': maritimeSkipped,
  };
}

Map<String, dynamic> _mergeProvincesOuterOnly(String newName, List<Map<String, dynamic>> provinces) {
  // Determine type
  String type = newName.startsWith('Thành phố') ? 'city' : 'province';
  int adminLevel = type == 'city' ? 3 : 4;
  
  // Merge bounding boxes
  double minLat = double.infinity, minLng = double.infinity;
  double maxLat = double.negativeInfinity, maxLng = double.negativeInfinity;
  
  // Thu thập tất cả outer rings (chỉ ring ngoài cùng, lọc biển)
  List<List<List<double>>> allOuterRings = [];
  int maritimeSkipped = 0;
  
  for (var province in provinces) {
    // Update bbox
    List<dynamic> bbox = province['bbox'] ?? [];
    if (bbox.length >= 4) {
      double south = (bbox[0] as num).toDouble();
      double west = (bbox[1] as num).toDouble();
      double north = (bbox[2] as num).toDouble();
      double east = (bbox[3] as num).toDouble();
      
      if (south < minLat) minLat = south;
      if (west < minLng) minLng = west;
      if (north > maxLat) maxLat = north;
      if (east > maxLng) maxLng = east;
    }
    
    // Lấy outer rings từ geometry
    Map<String, dynamic>? geometry = province['geometry'];
    if (geometry != null) {
      String geoType = geometry['type'] ?? '';
      List<dynamic> coords = geometry['coordinates'] ?? [];
      
      if (geoType == 'Polygon') {
        // Polygon: CHỈ lấy ring ĐẦU TIÊN (outer ring)
        if (coords.isNotEmpty) {
          var ring = _extractRing(coords[0]);
          if (!_isPolygonMaritime(ring)) {
            allOuterRings.add(ring);
          } else {
            maritimeSkipped++;
          }
        }
      } else if (geoType == 'MultiPolygon') {
        // MultiPolygon: Mỗi polygon chỉ lấy ring đầu tiên (outer)
        for (var polygon in coords) {
          if (polygon is List && polygon.isNotEmpty) {
            var ring = _extractRing(polygon[0]);
            if (!_isPolygonMaritime(ring)) {
              allOuterRings.add(ring);
            } else {
              maritimeSkipped++;
            }
          }
        }
      }
    }
  }
  
  // Convert to MultiPolygon format (mỗi outer ring là 1 polygon)
  List<List<List<List<double>>>> multiPolygon = 
      allOuterRings.map((ring) => [ring]).toList();
  
  return {
    'feature': {
      'name': newName,
      'type': type,
      'admin_level': adminLevel,
      'merged_from': provinces.map((p) => p['name']).toList(),
      'bbox': [minLat, minLng, maxLat, maxLng],
      'geometry': {
        'type': 'MultiPolygon',
        'coordinates': multiPolygon,
      },
    },
    'maritime_skipped': maritimeSkipped,
  };
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
