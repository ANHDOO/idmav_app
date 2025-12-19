// Service để quản lý dữ liệu Quốc lộ & Cao tốc VN từ assets
// Dùng cho tìm kiếm offline - thay thế Overpass API khi không có mạng

import 'dart:convert';
import 'dart:io'; 
import 'package:flutter/foundation.dart';
import 'dart:ui' show Color, StrokeCap, StrokeJoin;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';

/// Loại đường
enum RoadType {
  motorway,   // Cao tốc
  trunk,      // Quốc lộ chính
  primary,    // Quốc lộ
  secondary,  // Tỉnh lộ / Nhánh quốc lộ
  tertiary,   // Đường liên xã/huyện
  residential, // Đường dân sinh
  unclassified, // Đường chưa phân loại
}

/// Dữ liệu một tuyến đường
class VnRoadData {
  final String name;       // "Cao tốc Hà Nội - Hải Phòng"
  final String ref;        // "CT.03" hoặc "QL1"
  final RoadType roadType;
  final List<double> bbox; // [south, west, north, east]
  final List<List<LatLng>> segments; // Các đoạn đường (MultiLineString)

  VnRoadData({
    required this.name,
    required this.ref,
    required this.roadType,
    required this.bbox,
    required this.segments,
  });

  /// Kiểm tra bounds có giao với đường này không
  bool intersects(LatLngBounds bounds) {
    double south = bbox[0], west = bbox[1], north = bbox[2], east = bbox[3];
    return !(bounds.east < west || 
             bounds.west > east || 
             bounds.north < south || 
             bounds.south > north);
  }

  /// Tạo LatLngBounds từ bbox
  LatLngBounds get bounds => LatLngBounds(
    LatLng(bbox[0], bbox[1]),
    LatLng(bbox[2], bbox[3]),
  );

  /// Lấy màu theo loại đường
  Color get defaultColor {
    switch (roadType) {
      case RoadType.motorway:
        return const Color(0xFFE74C3C); // Đỏ - Cao tốc
      case RoadType.trunk:
        return const Color(0xFFE67E22); // Cam - Quốc lộ chính
      case RoadType.primary:
        return const Color(0xFFF1C40F); // Vàng - Quốc lộ
      case RoadType.secondary:
        return const Color(0xFF3498DB); // Xanh dương - Nhánh
      case RoadType.tertiary:
        return const Color(0xFFBDC3C7); // Xám trắng - Liên xã
      case RoadType.residential:
      case RoadType.unclassified:
        return const Color(0xFFECF0F1); // Trắng nhạt - Dân sinh
    }
  }

  /// Lấy độ rộng theo loại đường (Tăng độ dày để nhìn rõ hơn)
  double get defaultWidth {
    switch (roadType) {
      case RoadType.motorway:
        return 6.0; // Cao tốc - dày nhất
      case RoadType.trunk:
        return 5.0; // Quốc lộ chính
      case RoadType.primary:
        return 4.0; // Quốc lộ
      case RoadType.secondary:
        return 3.0; // Tỉnh lộ
      case RoadType.tertiary:
        return 2.5; // Liên xã
      case RoadType.residential:
      case RoadType.unclassified:
        return 2.0; // Dân sinh
    }
  }
  /// Tính tổng chiều dài tuyến đường (để lọc rác)
  double get totalLengthKm {
    final Distance distance = const Distance();
    double totalMeters = 0;
    
    for (var segment in segments) {
      for (int i = 0; i < segment.length - 1; i++) {
        totalMeters += distance.as(LengthUnit.Meter, segment[i], segment[i+1]);
      }
    }
    
    return totalMeters / 1000.0;
  }
}

/// Singleton service để quản lý dữ liệu đường
class RoadAssetService {
  static final RoadAssetService _instance = RoadAssetService._internal();
  factory RoadAssetService() => _instance;
  RoadAssetService._internal();

  // Cache dữ liệu
  List<VnRoadData> _roads = [];
  bool _isLoading = false;

  /// Kiểm tra đã load dữ liệu chưa
  bool get isLoaded => _roads.isNotEmpty;

  /// Số lượng đường đã load
  int get count => _roads.length;

  /// Danh sách đường
  List<VnRoadData> get roads => _roads;

  /// Load dữ liệu từ assets
  Future<bool> loadFromAssets() async {
    // Nếu đã load rồi thì return luôn
    if (_roads.isNotEmpty) return true;
    
    // Nếu đang load thì chờ
    if (_isLoading) {
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _roads.isNotEmpty;
    }

    _isLoading = true;

    try {
      String jsonString = '';
      bool loadedFromFile = false;

      // [DESKTOP] Ưu tiên load trực tiếp từ File System
      if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || 
                      defaultTargetPlatform == TargetPlatform.linux || 
                      defaultTargetPlatform == TargetPlatform.macOS)) {
         
         // 1. Check path khi chạy Debug (từ root project)
         File file = File('assets/roads/vn_roads.json');
         
         // 2. Check path khi Đóng gói (Release) trên Windows
         // Khi build .exe, assets sẽ nằm trong thư mục 'data/flutter_assets' bên cạnh file exe
         if (!await file.exists()) {
            file = File('data/flutter_assets/assets/roads/vn_roads.json');
         }

         if (await file.exists()) {
            try {
               print('📂 RoadAssetService: Đọc file trực tiếp từ đĩa: ${file.path}');
               jsonString = await file.readAsString();
               loadedFromFile = true;
            } catch (e) {
               print('⚠️ Lỗi đọc file trực tiếp: $e. Fallback về assets.');
            }
         }
      }

      if (!loadedFromFile) {
         jsonString = await rootBundle.loadString('assets/roads/vn_roads.json');
      }

      Map<String, dynamic> data = jsonDecode(jsonString);
      
      List<dynamic> features = data['features'] ?? [];
      List<VnRoadData> roads = [];

      for (var feature in features) {
        try {
          VnRoadData? road = _parseFeature(feature);
          if (road != null) roads.add(road);
        } catch (e) {
          print('⚠️ Lỗi parse road ${feature['ref']}: $e');
        }
      }

      
      // [REVERT] Không lọc đường rác nữa theo yêu cầu user
      _roads = roads;
      print('✅ RoadAssetService: Đã load ${roads.length} tuyến đường');
      return roads.isNotEmpty;
    } catch (e) {
      print('❌ RoadAssetService: Lỗi load assets: $e');
      return false;
    } finally {
      _isLoading = false;
    }
  }

  VnRoadData? _parseFeature(Map<String, dynamic> feature) {
    String name = feature['name'] ?? '';
    String ref = feature['ref'] ?? '';
    String roadTypeStr = feature['road_type'] ?? 'primary';
    List<double> bbox = (feature['bbox'] as List).map((e) => (e as num).toDouble()).toList();
    
    RoadType roadType;
    switch (roadTypeStr) {
      case 'motorway':
        roadType = RoadType.motorway;
        break;
      case 'trunk':
        roadType = RoadType.trunk;
        break;
      case 'secondary':
      case 'secondary_link':
        roadType = RoadType.secondary;
        break;
      case 'tertiary':
      case 'tertiary_link':
        roadType = RoadType.tertiary;
        break;
      case 'residential':
        roadType = RoadType.residential;
        break;
      case 'unclassified':
        roadType = RoadType.unclassified;
        break;
      default:
        // Nếu là đường link/nhánh mà không rơi vào các case trên -> Bỏ qua để đỡ rối
        if (roadTypeStr.contains('_link') || roadTypeStr.contains('link')) {
          return null; 
        }
        roadType = RoadType.primary;
    }
    
    Map<String, dynamic> geometry = feature['geometry'];
    List<List<LatLng>> segments = _parseGeometry(geometry);

    return VnRoadData(
      name: name,
      ref: ref,
      roadType: roadType,
      bbox: bbox,
      segments: segments,
    );
  }

  /// [MỚI] Hàm lọc bỏ đường rác
  List<VnRoadData> _filterNoise(List<VnRoadData> rawRoads) {
    return rawRoads.where((road) {
      double len = road.totalLengthKm;

      // 1. Cao tốc & Quốc lộ chính: Giữ hầu hết (chỉ bỏ quá vụn < 0.5km)
      if (road.roadType == RoadType.motorway || road.roadType == RoadType.trunk) {
        return len > 0.5;
      }
      
      // 2. Quốc lộ thường: Bỏ < 2km (thường là đoạn nối không tên)
      if (road.roadType == RoadType.primary) {
        return len > 2.0;
      }

      // 3. Đường nhỏ hơn: Bỏ < 3km (để tránh rác khi zoom xa)
      // Với mục đích "Dò Bit" thì cần đường dài, rõ ràng.
      return len > 3.0;
    }).toList();
  }

  List<List<LatLng>> _parseGeometry(Map<String, dynamic> geometry) {
    String geoType = geometry['type'];
    List<dynamic> coords = geometry['coordinates'];
    List<List<LatLng>> result = [];

    if (geoType == 'LineString') {
      List<LatLng> points = _parseLine(coords);
      if (points.isNotEmpty) result.add(points);
    } else if (geoType == 'MultiLineString') {
      for (var line in coords) {
        List<LatLng> points = _parseLine(line);
        if (points.isNotEmpty) result.add(points);
      }
    }

    return result;
  }

  List<LatLng> _parseLine(List<dynamic> line) {
    List<LatLng> points = [];
    for (var coord in line) {
      if (coord is List && coord.length >= 2) {
        double lng = (coord[0] as num).toDouble();
        double lat = (coord[1] as num).toDouble();
        points.add(LatLng(lat, lng));
      }
    }
    return points;
  }

  /// Chuẩn hóa chuỗi để so sánh (bỏ dấu, ký tự đặc biệt, lowercase)
  String _normalize(String input) {
    // Revert: Xóa hết ký tự đặc biệt để "ct07" match "CT.07"
    return input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  /// Kiểm tra match thông minh (keyword phải là từ trọn vẹn hoặc prefix)
  /// Xử lý cả trường hợp đa ref: "CT.07; CT.37"
  bool isSmartMatch(String rawSource, String rawKeyword) {
    String k = _normalize(rawKeyword);
    if (k.isEmpty) return false;

    // 1. Tách chuỗi nguồn thành các phần riêng biệt (nếu có dấu ngăn cách)
    // VD: "CT.07; CT.37" -> ["CT.07", "CT.37"]
    List<String> parts = rawSource.split(RegExp(r'[;,\/+]'));
    
    for (String part in parts) {
      String s = _normalize(part); // "CT.07" -> "ct07"
      
      // Match chính xác hoặc prefix
      int index = s.indexOf(k);
      if (index != -1) {
         // Kiểm tra ký tự ngay sau match (Boundary check)
         if (index + k.length < s.length) {
            String charAfter = s[index + k.length];
            // Nếu ký tự sau là số hoặc chữ -> Không phải match trọn vẹn (VD: QL1 vs QL15)
            if (RegExp(r'[a-z0-9]').hasMatch(charAfter)) continue; // Thử part khác
         }
         return true; // Match thành công
      }
    }
    
    return false;
  }

  /// Tìm đường theo ref (VD: "QL1", "CT.03")
  /// Trả về TẤT CẢ các VnRoadData có ref match (có thể nhiều entries)
  List<VnRoadData> findAllByRef(String ref) {
    if (!isLoaded) return [];
    
    return _roads.where((r) => isSmartMatch(r.ref, ref)).toList();
  }

  /// Tìm đường đầu tiên theo ref (backward compatibility)
  VnRoadData? findByRef(String ref) {
    if (!isLoaded) return null;
    
    try {
      return _roads.cast<VnRoadData?>().firstWhere(
        (r) => isSmartMatch(r!.ref, ref),
        orElse: () => null,
      );
    } catch (e) {
      return null;
    }
  }

  /// Tìm đường theo tên (partial match nhưng thông minh)
  List<VnRoadData> findByName(String name) {
    if (!isLoaded) return [];

    return _roads.where((r) {
      return isSmartMatch(r.name, name) || isSmartMatch(r.ref, name);
    }).toList();
  }

  /// Tìm tất cả đường giao với bounds
  List<VnRoadData> findRoadsInBounds(LatLngBounds bounds) {
    if (!isLoaded) return [];
    return _roads.where((r) => r.intersects(bounds)).toList();
  }

  /// Lấy danh sách gợi ý dựa trên từ khóa (tối đa 10 kết quả)
  /// Ưu tiên: 1. Ref khớp chính xác 2. Ref bắt đầu bằng query 3. Ref chứa query 4. Tên chứa query
  List<String> getSuggestions(String query) {
    if (!isLoaded || query.isEmpty) return [];
    
    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) return [];
    
    // Các prefix mã đường phổ biến
    const roadPrefixes = ['ct', 'ql', 'tl', 'hl', 'dt', 'ah'];
    
    // Kiểm tra xem query có phải là mã đường không (VD: CT, QL1, CT.01)
    bool isRoadCodeQuery = roadPrefixes.any((prefix) => normalizedQuery.startsWith(prefix));
    
    // Chia thành 4 nhóm ưu tiên (thứ tự giảm dần)
    final List<String> exactMatches = [];      // 1. Ref khớp chính xác (QL1 == QL1)
    final List<String> prefixMatches = [];     // 2. Ref bắt đầu bằng query (CT0 -> CT.01, CT.02)
    final List<String> refContains = [];       // 3. Ref chứa query (ít phổ biến)
    final List<String> nameContains = [];      // 4. Tên chứa query (ưu tiên thấp nhất)
    
    for (var road in _roads) {
      // Tách ref đa trị (VD: "QL.10;QL.37B" -> ["QL.10", "QL.37B"])
      List<String> refs = road.ref.split(RegExp(r'[;,]'));
      bool refMatched = false;

      for (var r in refs) {
        String cleanRef = r.trim();
        if (cleanRef.isEmpty) continue;
        
        String normalizedRef = _normalize(cleanRef);
        
        // 1. Khớp chính xác
        if (normalizedRef == normalizedQuery) {
          if (!exactMatches.contains(cleanRef)) exactMatches.add(cleanRef);
          refMatched = true;
        }
        // 2. Bắt đầu bằng query (ưu tiên cao)
        else if (normalizedRef.startsWith(normalizedQuery)) {
          if (!prefixMatches.contains(cleanRef)) prefixMatches.add(cleanRef);
          refMatched = true;
        }
        // 3. Ref chứa query (ưu tiên trung bình) - Chỉ khi không phải là road code query
        else if (!isRoadCodeQuery && normalizedRef.contains(normalizedQuery)) {
          if (!refContains.contains(cleanRef)) refContains.add(cleanRef);
          refMatched = true;
        }
      }

      // 4. Nếu ref không match và KHÔNG phải road code query -> check theo tên
      // Khi user đang gõ mã đường (CT., QL1...) thì KHÔNG tìm trong tên
      if (!refMatched && !isRoadCodeQuery) {
        String normalizedName = _normalize(road.name);
        if (normalizedName.contains(normalizedQuery)) {
          String primaryRef = refs.isNotEmpty ? refs.first.trim() : "";
          String suggestion = primaryRef.isNotEmpty ? '$primaryRef ${road.name}' : road.name;
          if (!nameContains.contains(suggestion)) nameContains.add(suggestion);
        }
      }
      
      // Giới hạn tìm kiếm sớm để tăng hiệu năng
      int total = exactMatches.length + prefixMatches.length + refContains.length + nameContains.length;
      if (total >= 30) break;
    }

    // Sắp xếp prefixMatches theo độ khớp (ngắn hơn = liên quan hơn)
    prefixMatches.sort((a, b) => _normalize(a).length.compareTo(_normalize(b).length));

    // Ghép 4 nhóm theo thứ tự ưu tiên
    List<String> result = [...exactMatches, ...prefixMatches, ...refContains, ...nameContains];
    return result.take(10).toList();
  }

  /// Lấy tất cả cao tốc
  List<VnRoadData> get allExpressways => 
    _roads.where((r) => r.roadType == RoadType.motorway).toList();

  /// Lấy tất cả quốc lộ (bao gồm nhánh)
  List<VnRoadData> get allNationalRoads => 
    _roads.where((r) => r.roadType != RoadType.motorway).toList();

  /// Chuyển VnRoadData thành danh sách Polyline để hiển thị trên map
  /// [optimize]: Gộp các đoạn và giảm điểm để tăng hiệu năng
  List<Polyline> toPolylines(
    VnRoadData road, {
    Color? color,
    double? strokeWidth,
  }) {
    // 1. Gộp các đoạn rời rạc nếu có thể
    List<List<LatLng>> merged = _mergeSegments(road.segments);
    
    // 2. Simplify nhẹ nhàng hơn để giữ độ nét (giống Online)
    List<List<LatLng>> simplified = [];
    
    // [REVERT] Trả về tolerance thấp (0.001) để giữ độ chính xác, không nội suy quá đà
    double tolerance = 0.001; 


    for (var segment in merged) {
      if (segment.length > 2) {
        var simple = simplify(segment, tolerance: tolerance, highestQuality: false);
        if (simple.length > 1) simplified.add(simple);
      } else {
        simplified.add(segment);
      }
    }

    return simplified.map((segment) => Polyline(
      points: segment,
      color: color ?? road.defaultColor,
      strokeWidth: strokeWidth ?? road.defaultWidth,
      borderStrokeWidth: 0, // Bỏ border để đường liền mạch
      strokeCap: StrokeCap.round, // Bo tròn đầu/cuối
      strokeJoin: StrokeJoin.round, // Bo tròn góc nối
    )).toList();
  }

  /// Gộp các đoạn thẳng nối tiếp nhau để giảm số lượng object Polyline
  List<List<LatLng>> _mergeSegments(List<List<LatLng>> segments) {
    if (segments.isEmpty) return [];
    
    List<List<LatLng>> result = [];
    List<List<LatLng>> pool = List.from(segments);
    
    while (pool.isNotEmpty) {
      List<LatLng> current = pool.removeAt(0);
      bool merged = true;
      
      while (merged) {
        merged = false;
        // Tìm đoạn nối đuôi
        for (int i = 0; i < pool.length; i++) {
          // Check nối đầu-đuôi
          if (_isSamePoint(current.last, pool[i].first)) {
            current.addAll(pool[i].sublist(1));
            pool.removeAt(i);
            merged = true;
            break;
          }
          // Check nối đầu-đầu (đảo chiều)
          else if (_isSamePoint(current.last, pool[i].last)) {
            current.addAll(pool[i].reversed.toList().sublist(1));
            pool.removeAt(i);
            merged = true;
            break;
          }
           // Check nối đuôi-đầu (insert đầu)
          else if (_isSamePoint(current.first, pool[i].last)) {
            current.insertAll(0, pool[i].sublist(0, pool[i].length - 1));
            pool.removeAt(i);
            merged = true;
            break;
          }
          // Check nối đuôi-đuôi (đảo chiều + insert đầu)
          else if (_isSamePoint(current.first, pool[i].first)) {
            current.insertAll(0, pool[i].reversed.toList().sublist(0, pool[i].length - 1));
            pool.removeAt(i);
            merged = true;
            break;
          }
        }
      }
      result.add(current);
    }
    return result;
  }
  
  bool _isSamePoint(LatLng p1, LatLng p2) {
    // Tăng dung sai lên 0.001 (~100m) để nối được nhiều đoạn hơn, giống kết quả online
    return (p1.latitude - p2.latitude).abs() < 0.001 && 
           (p1.longitude - p2.longitude).abs() < 0.001;
  }

  
  // Implements Douglas-Peucker algorithm
  List<LatLng> simplify(List<LatLng> points, {double tolerance = 1.0, bool highestQuality = false}) {
    if (points.length <= 2) return points;
    // List<LatLng> sqPoints = points; // Unused variable
    
    // (Giản lược thuật toán ở đây hoặc dùng package 'simplify' nếu có - tuy nhiên code này tự implement cho nhanh)
    // Code simplify đơn giản dựa trên khoảng cách
    return _simplifyEasy(points, tolerance);
  }

  List<LatLng> _simplifyEasy(List<LatLng> points, double tolerance) {
     if (points.length < 3) return points;
    List<LatLng> result = [points.first];
    for (int i = 1; i < points.length - 1; i++) {
      double d = (points[i].latitude - result.last.latitude).abs() + 
                 (points[i].longitude - result.last.longitude).abs();
      if (d > tolerance) {
        result.add(points[i]);
      }
    }
    result.add(points.last);
    return result;
  }

  /// Xóa cache để reload dữ liệu
  void clearCache() {
    _roads = [];
  }

  /// Reload lại dữ liệu từ assets (xoá cache cũ)
  Future<bool> reloadFromAssets() async {
    clearCache();
    _isLoading = false; // Reset loading state
    return loadFromAssets();
  }
}
