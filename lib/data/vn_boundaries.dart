// Service để quản lý dữ liệu ranh giới tỉnh VN từ assets
// Hỗ trợ 2 bộ dữ liệu: 63 tỉnh (hiện tại) và 34 tỉnh (sau sáp nhập 2025)

import 'dart:convert';
import 'dart:ui' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';

/// Loại dữ liệu ranh giới
enum BoundaryDataVersion {
  current63, // 63 tỉnh hiện tại
  merged34,  // 34 tỉnh sau sáp nhập 2025
}

/// Dữ liệu ranh giới một tỉnh/quốc gia
class VnBoundaryData {
  final String name;
  final String type; // 'province', 'city', 'country'
  final int adminLevel;
  final List<double> bbox; // [south, west, north, east]
  final List<List<LatLng>> polygons;
  final List<String>? mergedFrom; // Danh sách tỉnh cũ đã gộp (chỉ có ở version 2025)

  VnBoundaryData({
    required this.name,
    required this.type,
    required this.adminLevel,
    required this.bbox,
    required this.polygons,
    this.mergedFrom,
  });

  /// Kiểm tra bounds có giao với tỉnh này không
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
}

/// Singleton service để quản lý dữ liệu ranh giới
class BoundaryAssetService {
  static final BoundaryAssetService _instance = BoundaryAssetService._internal();
  factory BoundaryAssetService() => _instance;
  BoundaryAssetService._internal();

  // Cache cho cả 2 version
  final Map<BoundaryDataVersion, List<VnBoundaryData>> _cache = {};
  final Map<BoundaryDataVersion, bool> _loadingState = {};
  
  // Version đang sử dụng
  BoundaryDataVersion _currentVersion = BoundaryDataVersion.current63;

  /// Lấy/đặt version đang sử dụng
  BoundaryDataVersion get currentVersion => _currentVersion;
  set currentVersion(BoundaryDataVersion version) {
    _currentVersion = version;
  }

  /// Kiểm tra đã load dữ liệu chưa (cho version hiện tại)
  bool get isLoaded => _cache.containsKey(_currentVersion) && _cache[_currentVersion]!.isNotEmpty;

  /// Số lượng ranh giới đã load (cho version hiện tại)
  int get count => _cache[_currentVersion]?.length ?? 0;

  /// Danh sách ranh giới hiện tại
  List<VnBoundaryData> get boundaries => _cache[_currentVersion] ?? [];

  /// Path tới file JSON theo version
  String _getAssetPath(BoundaryDataVersion version) {
    switch (version) {
      case BoundaryDataVersion.current63:
        return 'assets/boundaries/vn_boundaries.json';
      case BoundaryDataVersion.merged34:
        return 'assets/boundaries/vn_boundaries_2025.json';
    }
  }

  /// Load dữ liệu từ assets
  Future<bool> loadFromAssets({BoundaryDataVersion? version}) async {
    version ??= _currentVersion;
    
    // Nếu đã load rồi thì return luôn
    if (_cache.containsKey(version) && _cache[version]!.isNotEmpty) {
      return true;
    }
    
    // Nếu đang load thì chờ
    if (_loadingState[version] == true) {
      while (_loadingState[version] == true) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _cache.containsKey(version) && _cache[version]!.isNotEmpty;
    }

    _loadingState[version] = true;

    try {
      String assetPath = _getAssetPath(version);
      String jsonString = await rootBundle.loadString(assetPath);
      Map<String, dynamic> data = jsonDecode(jsonString);
      
      List<dynamic> features = data['features'] ?? [];
      List<VnBoundaryData> boundaries = [];

      for (var feature in features) {
        try {
          VnBoundaryData boundary = _parseFeature(feature);
          boundaries.add(boundary);
        } catch (e) {
          print('⚠️ Lỗi parse feature ${feature['name']}: $e');
        }
      }

      _cache[version] = boundaries;
      
      String versionName = version == BoundaryDataVersion.merged34 ? '34 tỉnh 2025' : '63 tỉnh';
      print('✅ BoundaryAssetService: Đã load ${boundaries.length} ranh giới ($versionName)');
      return boundaries.isNotEmpty;
    } catch (e) {
      print('❌ BoundaryAssetService: Lỗi load assets: $e');
      return false;
    } finally {
      _loadingState[version] = false;
    }
  }

  VnBoundaryData _parseFeature(Map<String, dynamic> feature) {
    String name = feature['name'] ?? '';
    String type = feature['type'] ?? 'province';
    int adminLevel = feature['admin_level'] ?? 4;
    List<double> bbox = (feature['bbox'] as List).map((e) => (e as num).toDouble()).toList();
    
    // Lấy danh sách tỉnh đã gộp (nếu có)
    List<String>? mergedFrom;
    if (feature['merged_from'] != null) {
      mergedFrom = (feature['merged_from'] as List).map((e) => e.toString()).toList();
    }
    
    Map<String, dynamic> geometry = feature['geometry'];
    List<List<LatLng>> polygons = _parseGeometry(geometry);

    return VnBoundaryData(
      name: name,
      type: type,
      adminLevel: adminLevel,
      bbox: bbox,
      polygons: polygons,
      mergedFrom: mergedFrom,
    );
  }

  List<List<LatLng>> _parseGeometry(Map<String, dynamic> geometry) {
    String geoType = geometry['type'];
    List<dynamic> coords = geometry['coordinates'];
    List<List<LatLng>> result = [];

    if (geoType == 'Polygon') {
      for (var ring in coords) {
        List<LatLng> points = _parseRing(ring);
        if (points.isNotEmpty) result.add(points);
      }
    } else if (geoType == 'MultiPolygon') {
      for (var polygon in coords) {
        for (var ring in polygon) {
          List<LatLng> points = _parseRing(ring);
          if (points.isNotEmpty) result.add(points);
        }
      }
    }

    return result;
  }

  List<LatLng> _parseRing(List<dynamic> ring) {
    List<LatLng> points = [];
    for (var coord in ring) {
      if (coord is List && coord.length >= 2) {
        double lng = (coord[0] as num).toDouble();
        double lat = (coord[1] as num).toDouble();
        points.add(LatLng(lat, lng));
      }
    }
    return points;
  }

  /// Tìm tất cả tỉnh/ranh giới giao với bounds
  List<VnBoundaryData> findBoundariesInBounds(LatLngBounds bounds) {
    if (!isLoaded) return [];
    return boundaries.where((b) => b.intersects(bounds)).toList();
  }

  /// Tìm theo tên (case-insensitive, partial match)
  VnBoundaryData? findByName(String name) {
    if (!isLoaded) return null;
    String lowerName = name.toLowerCase();
    return boundaries.cast<VnBoundaryData?>().firstWhere(
      (b) => b!.name.toLowerCase().contains(lowerName),
      orElse: () => null,
    );
  }

  /// Lấy biên giới quốc gia Việt Nam
  VnBoundaryData? get vietnamBorder {
    if (!isLoaded) return null;
    return boundaries.cast<VnBoundaryData?>().firstWhere(
      (b) => b!.type == 'country',
      orElse: () => null,
    );
  }

  /// Lấy danh sách tất cả tỉnh (không bao gồm biên giới quốc gia)
  List<VnBoundaryData> get allProvinces {
    if (!isLoaded) return [];
    return boundaries.where((b) => b.type == 'province' || b.type == 'city').toList();
  }

  /// Chuyển VnBoundaryData thành danh sách Polyline để hiển thị trên map
  List<Polyline> toPolylines(
    VnBoundaryData boundary, {
    Color color = const Color(0xFFAB47BC),
    double strokeWidth = 3.0,
    bool isDotted = true,
  }) {
    return boundary.polygons.map((polygon) => Polyline(
      points: polygon,
      color: color,
      strokeWidth: strokeWidth,
      isDotted: isDotted,
    )).toList();
  }

  /// Xóa cache để reload dữ liệu
  void clearCache({BoundaryDataVersion? version}) {
    if (version != null) {
      _cache.remove(version);
    } else {
      _cache.clear();
    }
  }
}
