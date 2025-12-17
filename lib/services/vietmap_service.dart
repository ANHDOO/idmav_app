import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/material.dart';

/// VietMap API Service
/// Cung cấp các tính năng: Search, Reverse Geocoding, Routing
class VietMapService {
  // Singleton pattern
  static final VietMapService _instance = VietMapService._internal();
  factory VietMapService() => _instance;
  VietMapService._internal();

  // ==================== CẤU HÌNH API KEY ====================
  // Key Services (đầu 53c9...)
  static const String _servicesApiKey = '53c96cf1e0b08a06dbe98befdc0f7c3e3de8394853fc9844';
  
  // Base URLs
  static const String _searchBaseUrl = 'https://maps.vietmap.vn/api/search/v3';
  static const String _autocompleteBaseUrl = 'https://maps.vietmap.vn/api/autocomplete/v3';
  static const String _reverseBaseUrl = 'https://maps.vietmap.vn/api/reverse/v3';
  static const String _routeBaseUrl = 'https://maps.vietmap.vn/api/route';

  // ==================== 1. SEARCH API ====================
  
  /// Tìm kiếm địa điểm/đường theo từ khóa
  Future<List<VietMapSearchResult>> search(
    String query, {
    LatLng? location,
    LatLngBounds? bounds,
    int limit = 20,
  }) async {
    try {
      final uri = Uri.parse('$_searchBaseUrl').replace(queryParameters: {
        'apikey': _servicesApiKey,
        'text': query,
        if (location != null) 'focus.point.lat': location.latitude.toString(),
        if (location != null) 'focus.point.lon': location.longitude.toString(),
        if (bounds != null) 'boundary.rect.min_lat': bounds.south.toString(),
        if (bounds != null) 'boundary.rect.max_lat': bounds.north.toString(),
        if (bounds != null) 'boundary.rect.min_lon': bounds.west.toString(),
        if (bounds != null) 'boundary.rect.max_lon': bounds.east.toString(),
        'size': limit.toString(),
      });

      debugPrint('🔍 VietMap Search: $uri');
      
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        // [FIX ERROR]: Decode dynamic để kiểm tra kiểu dữ liệu
        final dynamic data = jsonDecode(response.body);
        
        // [QUAN TRỌNG] Kiểm tra xem data có phải là Map không.
        // Nếu API trả về List [] (khi không tìm thấy hoặc lỗi), ta return rỗng ngay.
        if (data is! Map) {
          debugPrint('⚠️ VietMap API trả về List thay vì Map (Có thể không có kết quả)');
          return [];
        }

        List<VietMapSearchResult> results = [];
        
        // Kiểm tra an toàn 'features'
        if (data['features'] != null && data['features'] is List) {
          for (var feature in data['features']) {
            // Đảm bảo mỗi feature là một Map trước khi parse
            if (feature is Map<String, dynamic>) {
              results.add(VietMapSearchResult.fromGeoJson(feature));
            } else if (feature is Map) {
               // Cast an toàn nếu feature là Map<dynamic, dynamic>
               results.add(VietMapSearchResult.fromGeoJson(Map<String, dynamic>.from(feature)));
            }
          }
        }
        
        debugPrint('✅ VietMap Search: Tìm thấy ${results.length} kết quả');
        return results;
      } else {
        debugPrint('❌ VietMap Search Error: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('❌ VietMap Search Exception: $e');
      return [];
    }
  }

  /// Gợi ý tự động khi người dùng gõ
  Future<List<VietMapSearchResult>> autocomplete(
    String query, {
    LatLng? location,
    int limit = 10,
  }) async {
    if (query.length < 2) return [];
    
    try {
      final uri = Uri.parse('$_autocompleteBaseUrl').replace(queryParameters: {
        'apikey': _servicesApiKey,
        'text': query,
        if (location != null) 'focus.point.lat': location.latitude.toString(),
        if (location != null) 'focus.point.lon': location.longitude.toString(),
        'size': limit.toString(),
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        
        // [FIX ERROR] Tương tự hàm search, kiểm tra kiểu dữ liệu
        if (data is! Map) return [];

        List<VietMapSearchResult> results = [];
        
        if (data['features'] != null && data['features'] is List) {
          for (var feature in data['features']) {
            if (feature is Map) {
               results.add(VietMapSearchResult.fromGeoJson(Map<String, dynamic>.from(feature)));
            }
          }
        }
        return results;
      }
      return [];
    } catch (e) {
      debugPrint('❌ VietMap Autocomplete Exception: $e');
      return [];
    }
  }

  // ==================== 2. REVERSE GEOCODING ====================
  
  /// Lấy thông tin địa chỉ từ tọa độ
  Future<VietMapAddress?> reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.parse('$_reverseBaseUrl').replace(queryParameters: {
        'apikey': _servicesApiKey,
        'point.lat': lat.toString(),
        'point.lon': lng.toString(),
        'size': '1',
      });

      debugPrint('📍 VietMap Reverse: $uri');
      
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        if (data is! Map) return null; // [FIX ERROR]
        
        if (data['features'] != null && data['features'] is List && (data['features'] as List).isNotEmpty) {
          final feature = data['features'][0];
          if (feature is Map) {
             return VietMapAddress.fromGeoJson(Map<String, dynamic>.from(feature));
          }
        }
      } else {
        debugPrint('❌ VietMap Reverse Error: ${response.statusCode}');
      }
      return null;
    } catch (e) {
      debugPrint('❌ VietMap Reverse Exception: $e');
      return null;
    }
  }

  // ==================== 3. ROUTING API ====================
  
  /// Tính tuyến đường từ điểm A đến điểm B
  Future<VietMapRoute?> getRoute(
    LatLng origin, 
    LatLng destination, {
    String vehicle = 'car',
  }) async {
    try {
      final String originPoint = '${origin.latitude},${origin.longitude}';
      final String destPoint = '${destination.latitude},${destination.longitude}';
      
      final String url = '$_routeBaseUrl'
          '?api-version=1.1'
          '&apikey=$_servicesApiKey'
          '&point=$originPoint'
          '&point=$destPoint'
          '&vehicle=$vehicle'
          '&points_encoded=false';

      debugPrint('🛣️ VietMap Route: $url');
      
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      
      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        if (data is! Map) return null; // [FIX ERROR]
        
        if (data['paths'] != null && data['paths'] is List && (data['paths'] as List).isNotEmpty) {
          return VietMapRoute.fromJson(data['paths'][0]);
        }
      } else {
        debugPrint('❌ VietMap Route Error: ${response.statusCode} - ${response.body}');
      }
      return null;
    } catch (e) {
      debugPrint('❌ VietMap Route Exception: $e');
      return null;
    }
  }

  /// Helper: Tính toán và trả về Polyline để vẽ lên map ngay lập tức
  Future<List<Polyline>> getRoutePolylines(
    LatLng origin, 
    LatLng destination, {
    Color color = Colors.blue,
    double strokeWidth = 6.0,
  }) async {
    final route = await getRoute(origin, destination);
    if (route == null || route.points.isEmpty) return [];
    
    return [
      Polyline(
        points: route.points,
        color: color,
        strokeWidth: strokeWidth,
        borderColor: Colors.white,
        borderStrokeWidth: 2.0,
        strokeCap: StrokeCap.round,
        strokeJoin: StrokeJoin.round,
      ),
    ];
  }
}

// ==================== DATA MODELS ====================

class VietMapSearchResult {
  final String id;
  final String name;
  final String label;
  final String? street;
  final String? locality;
  final String? region;
  final String? country;
  final LatLng location;
  final String? layer;
  
  VietMapSearchResult({
    required this.id,
    required this.name,
    required this.label,
    this.street,
    this.locality,
    this.region,
    this.country,
    required this.location,
    this.layer,
  });

  factory VietMapSearchResult.fromGeoJson(Map<String, dynamic> feature) {
    final properties = feature['properties'] ?? {};
    final geometry = feature['geometry'] ?? {};
    final coordinates = geometry['coordinates'] ?? [0.0, 0.0];
    
    return VietMapSearchResult(
      id: properties['id']?.toString() ?? '',
      name: properties['name'] ?? '',
      label: properties['label'] ?? properties['name'] ?? '',
      street: properties['street'],
      locality: properties['locality'],
      region: properties['region'],
      country: properties['country'],
      location: LatLng(
        (coordinates[1] as num).toDouble(),
        (coordinates[0] as num).toDouble(),
      ),
      layer: properties['layer'],
    );
  }

  @override
  String toString() => label;
}

class VietMapAddress {
  final String name;
  final String label;
  final String? houseNumber;
  final String? street;
  final String? locality;
  final String? district;
  final String? region;
  final String? country;
  final LatLng location;
  final double? distance;
  
  VietMapAddress({
    required this.name,
    required this.label,
    this.houseNumber,
    this.street,
    this.locality,
    this.district,
    this.region,
    this.country,
    required this.location,
    this.distance,
  });

  factory VietMapAddress.fromGeoJson(Map<String, dynamic> feature) {
    final properties = feature['properties'] ?? {};
    final geometry = feature['geometry'] ?? {};
    final coordinates = geometry['coordinates'] ?? [0.0, 0.0];
    
    return VietMapAddress(
      name: properties['name'] ?? '',
      label: properties['label'] ?? '',
      houseNumber: properties['housenumber'],
      street: properties['street'],
      locality: properties['locality'],
      district: properties['localadmin'] ?? properties['county'],
      region: properties['region'],
      country: properties['country'],
      location: LatLng(
        (coordinates[1] as num).toDouble(),
        (coordinates[0] as num).toDouble(),
      ),
      distance: properties['distance']?.toDouble(),
    );
  }

  String get streetName => street ?? name;
  
  String get shortAddress {
    List<String> parts = [];
    if (houseNumber != null) parts.add(houseNumber!);
    if (street != null) parts.add(street!);
    if (locality != null) parts.add(locality!);
    return parts.join(', ');
  }

  @override
  String toString() => label;
}

class VietMapRoute {
  final double distance;
  final double time;
  final List<LatLng> points;
  final String? instructions;
  
  VietMapRoute({
    required this.distance,
    required this.time,
    required this.points,
    this.instructions,
  });

  factory VietMapRoute.fromJson(Map<String, dynamic> json) {
    List<LatLng> routePoints = [];
    if (json['points'] != null) {
      if (json['points'] is Map && json['points']['coordinates'] != null) {
        for (var coord in json['points']['coordinates']) {
          routePoints.add(LatLng(
            (coord[1] as num).toDouble(),
            (coord[0] as num).toDouble(),
          ));
        }
      }
    }
    
    return VietMapRoute(
      distance: (json['distance'] as num?)?.toDouble() ?? 0,
      time: (json['time'] as num?)?.toDouble() ?? 0,
      points: routePoints,
    );
  }

  String get distanceFormatted {
    if (distance >= 1000) {
      return '${(distance / 1000).toStringAsFixed(1)} km';
    }
    return '${distance.toInt()} m';
  }

  String get timeFormatted {
    int totalMinutes = (time / 60000).round();
    if (totalMinutes >= 60) {
      int hours = totalMinutes ~/ 60;
      int minutes = totalMinutes % 60;
      return '${hours}h ${minutes}m';
    }
    return '$totalMinutes phút';
  }
}