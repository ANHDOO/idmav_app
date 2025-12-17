// Script để tạo file vn_boundaries.json từ Nominatim API
// Chạy: dart run tools/generate_boundaries.dart
// 
// Sử dụng Nominatim vì cho ra geometry chính xác hơn Overpass

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// Danh sách 63 tỉnh/thành phố Việt Nam
const List<String> vietnamProvinces = [
  // Miền Bắc - Đồng bằng sông Hồng
  "Hà Nội",
  "Hải Phòng",
  "Hải Dương",
  "Hưng Yên",
  "Thái Bình",
  "Nam Định",
  "Hà Nam",
  "Ninh Bình",
  "Vĩnh Phúc",
  "Bắc Ninh",
  // Miền Bắc - Đông Bắc
  "Quảng Ninh",
  "Bắc Giang",
  "Lạng Sơn",
  "Cao Bằng",
  "Bắc Kạn",
  "Thái Nguyên",
  // Miền Bắc - Tây Bắc
  "Phú Thọ",
  "Tuyên Quang",
  "Hà Giang",
  "Lào Cai",
  "Yên Bái",
  "Lai Châu",
  "Điện Biên",
  "Sơn La",
  "Hòa Bình",
  // Miền Trung - Bắc Trung Bộ
  "Thanh Hóa",
  "Nghệ An",
  "Hà Tĩnh",
  "Quảng Bình",
  "Quảng Trị",
  "Thừa Thiên Huế",
  // Miền Trung - Nam Trung Bộ
  "Đà Nẵng",
  "Quảng Nam",
  "Quảng Ngãi",
  "Bình Định",
  "Phú Yên",
  "Khánh Hòa",
  "Ninh Thuận",
  "Bình Thuận",
  // Tây Nguyên
  "Kon Tum",
  "Gia Lai",
  "Đắk Lắk",
  "Đắk Nông",
  "Lâm Đồng",
  // Đông Nam Bộ
  "Hồ Chí Minh",
  "Bà Rịa - Vũng Tàu",
  "Đồng Nai",
  "Bình Dương",
  "Bình Phước",
  "Tây Ninh",
  // Tây Nam Bộ - Đồng bằng sông Cửu Long
  "Long An",
  "Tiền Giang",
  "Bến Tre",
  "Vĩnh Long",
  "Trà Vinh",
  "Đồng Tháp",
  "An Giang",
  "Kiên Giang",
  "Cần Thơ",
  "Hậu Giang",
  "Sóc Trăng",
  "Bạc Liêu",
  "Cà Mau",
];

class NominatimFetcher {
  final HttpClient _client = HttpClient();
  int _requestCount = 0;
  
  Future<Map<String, dynamic>?> fetchProvince(String provinceName) async {
    try {
      // Rate limiting: Nominatim yêu cầu 1 request/giây
      _requestCount++;
      
      String query = Uri.encodeQueryComponent('$provinceName, Việt Nam');
      String url = 'https://nominatim.openstreetmap.org/search?'
          'q=$query&format=json&polygon_geojson=1&limit=1'
          '&accept-language=vi&countrycodes=vn';
      
      final request = await _client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'VN-Boundary-Generator/1.0');
      
      final response = await request.close();
      
      if (response.statusCode == 200) {
        String body = await response.transform(utf8.decoder).join();
        List<dynamic> results = jsonDecode(body);
        
        if (results.isNotEmpty) {
          var result = results[0];
          
          // Kiểm tra có geometry không
          if (result['geojson'] != null) {
            // Lấy bounding box
            List<String> bbox = (result['boundingbox'] as List).cast<String>();
            
            return {
              'name': provinceName,
              'type': 'province',
              'admin_level': 4,
              'osm_id': result['osm_id'],
              'bbox': [
                double.parse(bbox[0]), // south
                double.parse(bbox[2]), // west
                double.parse(bbox[1]), // north
                double.parse(bbox[3]), // east
              ],
              'geometry': result['geojson'],
            };
          }
        }
      } else {
        print('❌ HTTP ${response.statusCode} for $provinceName');
      }
    } catch (e) {
      print('❌ Error fetching $provinceName: $e');
    }
    return null;
  }
  
  Future<Map<String, dynamic>?> fetchCountryBorder() async {
    try {
      String url = 'https://nominatim.openstreetmap.org/search?'
          'q=Việt Nam&format=json&polygon_geojson=1&limit=1'
          '&accept-language=vi';
      
      final request = await _client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'VN-Boundary-Generator/1.0');
      
      final response = await request.close();
      
      if (response.statusCode == 200) {
        String body = await response.transform(utf8.decoder).join();
        List<dynamic> results = jsonDecode(body);
        
        if (results.isNotEmpty) {
          var result = results[0];
          
          if (result['geojson'] != null) {
            List<String> bbox = (result['boundingbox'] as List).cast<String>();
            
            return {
              'name': 'Việt Nam',
              'type': 'country',
              'admin_level': 2,
              'osm_id': result['osm_id'],
              'bbox': [
                double.parse(bbox[0]),
                double.parse(bbox[2]),
                double.parse(bbox[1]),
                double.parse(bbox[3]),
              ],
              'geometry': result['geojson'],
            };
          }
        }
      }
    } catch (e) {
      print('❌ Error fetching Vietnam border: $e');
    }
    return null;
  }
  
  void close() {
    _client.close();
  }
}

// Simplify geometry để giảm dung lượng
List<List<double>> simplifyLine(List<List<double>> points, double tolerance) {
  if (points.length < 3) return points;
  
  // Douglas-Peucker algorithm
  double maxDist = 0;
  int maxIdx = 0;
  
  for (int i = 1; i < points.length - 1; i++) {
    double dist = perpendicularDistance(points[i], points[0], points[points.length - 1]);
    if (dist > maxDist) {
      maxDist = dist;
      maxIdx = i;
    }
  }
  
  if (maxDist > tolerance) {
    List<List<double>> left = simplifyLine(points.sublist(0, maxIdx + 1), tolerance);
    List<List<double>> right = simplifyLine(points.sublist(maxIdx), tolerance);
    return [...left.sublist(0, left.length - 1), ...right];
  } else {
    return [points.first, points.last];
  }
}

double perpendicularDistance(List<double> point, List<double> lineStart, List<double> lineEnd) {
  double dx = lineEnd[0] - lineStart[0];
  double dy = lineEnd[1] - lineStart[1];
  
  if (dx == 0 && dy == 0) {
    dx = point[0] - lineStart[0];
    dy = point[1] - lineStart[1];
    return math.sqrt(dx * dx + dy * dy);
  }
  
  double t = ((point[0] - lineStart[0]) * dx + (point[1] - lineStart[1]) * dy) / (dx * dx + dy * dy);
  t = t.clamp(0.0, 1.0);
  
  double nearestX = lineStart[0] + t * dx;
  double nearestY = lineStart[1] + t * dy;
  
  dx = point[0] - nearestX;
  dy = point[1] - nearestY;
  
  return math.sqrt(dx * dx + dy * dy);
}

Map<String, dynamic> simplifyGeometry(Map<String, dynamic> geometry, double tolerance) {
  String type = geometry['type'];
  
  if (type == 'Polygon') {
    List<dynamic> coords = geometry['coordinates'];
    List<List<List<double>>> simplified = [];
    
    for (var ring in coords) {
      List<List<double>> points = (ring as List).map((p) => 
        [(p as List)[0] as double, p[1] as double]
      ).toList();
      
      simplified.add(simplifyLine(points, tolerance));
    }
    
    return {'type': 'Polygon', 'coordinates': simplified};
  } else if (type == 'MultiPolygon') {
    List<dynamic> coords = geometry['coordinates'];
    List<List<List<List<double>>>> simplified = [];
    
    for (var polygon in coords) {
      List<List<List<double>>> simplifiedPolygon = [];
      
      for (var ring in (polygon as List)) {
        List<List<double>> points = (ring as List).map((p) => 
          [(p as List)[0] as double, p[1] as double]
        ).toList();
        
        simplifiedPolygon.add(simplifyLine(points, tolerance));
      }
      
      simplified.add(simplifiedPolygon);
    }
    
    return {'type': 'MultiPolygon', 'coordinates': simplified};
  }
  
  return geometry;
}

Future<void> main() async {
  print('🚀 Bắt đầu tải dữ liệu ranh giới từ Nominatim...');
  print('📦 Sẽ tải: 1 biên giới quốc gia + ${vietnamProvinces.length} tỉnh/thành\n');
  
  final fetcher = NominatimFetcher();
  List<Map<String, dynamic>> features = [];
  
  // 1. Tải biên giới quốc gia trước
  print('🌏 Đang tải biên giới Việt Nam...');
  var countryData = await fetcher.fetchCountryBorder();
  if (countryData != null) {
    // Simplify để giảm dung lượng (tolerance = 0.001 ~ 100m)
    countryData['geometry'] = simplifyGeometry(countryData['geometry'], 0.002);
    features.add(countryData);
    print('✅ Đã tải biên giới Việt Nam');
  } else {
    print('❌ Không tải được biên giới Việt Nam');
  }
  
  await Future.delayed(Duration(seconds: 1)); // Rate limit
  
  // 2. Tải 63 tỉnh - Chạy 5 luồng song song (Nominatim rate limit)
  const int batchSize = 5;
  int completed = 0;
  
  for (int i = 0; i < vietnamProvinces.length; i += batchSize) {
    int end = math.min(i + batchSize, vietnamProvinces.length);
    List<String> batch = vietnamProvinces.sublist(i, end);
    
    // Tải song song batch
    List<Future<Map<String, dynamic>?>> futures = [];
    for (int j = 0; j < batch.length; j++) {
      // Stagger requests trong batch để tránh hit server cùng lúc
      futures.add(
        Future.delayed(Duration(milliseconds: j * 200), () => fetcher.fetchProvince(batch[j]))
      );
    }
    
    var results = await Future.wait(futures);
    
    for (var result in results) {
      if (result != null) {
        // Simplify geometry
        result['geometry'] = simplifyGeometry(result['geometry'], 0.001);
        features.add(result);
        completed++;
        print('✅ [${completed}/${vietnamProvinces.length}] ${result['name']}');
      }
    }
    
    // Rate limit giữa các batch
    if (end < vietnamProvinces.length) {
      print('   ⏳ Chờ 1s để tránh rate limit...');
      await Future.delayed(Duration(seconds: 1));
    }
  }
  
  fetcher.close();
  
  // 3. Tạo JSON output
  Map<String, dynamic> output = {
    'version': '1.0',
    'generated': DateTime.now().toIso8601String().split('T')[0],
    'source': 'Nominatim OpenStreetMap',
    'total': features.length,
    'features': features,
  };
  
  // 4. Lưu file
  String outputPath = 'assets/boundaries/vn_boundaries.json';
  File outputFile = File(outputPath);
  await outputFile.parent.create(recursive: true);
  
  String jsonString = JsonEncoder.withIndent('  ').convert(output);
  await outputFile.writeAsString(jsonString);
  
  int fileSizeKB = (await outputFile.length()) ~/ 1024;
  print('\n✅ Hoàn thành!');
  print('📁 File: $outputPath');
  print('📊 Kích thước: ${fileSizeKB} KB');
  print('📝 Số features: ${features.length}');
}
