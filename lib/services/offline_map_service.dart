import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mbtiles/mbtiles.dart';

/// Service quản lý bản đồ offline + Hybrid Mode
/// 1. Kiểm tra mạng: Có mạng -> Dùng Online API
/// 2. Mất mạng -> Dùng file .mbtiles đã bundle (hoặc copy từ assets)
class OfflineMapService {
  static final OfflineMapService _instance = OfflineMapService._internal();
  factory OfflineMapService() => _instance;
  OfflineMapService._internal();

  // Tên file trong assets
  static const String _bundledFileName = 'vietnam_map.mbtiles';
  static const String _vietmapFileName = 'vietnam_vietmap.mbtiles';
  
  bool _isInitialized = false;
  MbTilesTileProvider? _offlineProvider; // Google Maps
  MbTilesTileProvider? _vietmapOfflineProvider; // VietMap
  
  // Network state
  bool _isOnline = true;
  final StreamController<bool> _networkStatusController = StreamController.broadcast();
  Stream<bool> get onNetworkStatusChanged => _networkStatusController.stream;
  
  /// Khởi tạo Service
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    // 1. Monitor Network
    Connectivity().onConnectivityChanged.listen((dynamic result) {
      bool hasNet = false;
      if (result is List<ConnectivityResult>) {
        hasNet = result.contains(ConnectivityResult.mobile) || 
                 result.contains(ConnectivityResult.wifi) ||
                 result.contains(ConnectivityResult.ethernet);
      } else {
        // ConnectivityResult (v5)
        hasNet = result == ConnectivityResult.mobile || 
                 result == ConnectivityResult.wifi || 
                 result == ConnectivityResult.ethernet;
      }
      
      if (_isOnline != hasNet) {
        _isOnline = hasNet;
        _networkStatusController.add(_isOnline);
        debugPrint('🌐 Network Status: ${_isOnline ? "ONLINE" : "OFFLINE"}');
      }
    });

    // Check initial state
    // Cast to dynamic to avoid static type error on v5
    final dynamic initResult = await Connectivity().checkConnectivity();
    if (initResult is List<ConnectivityResult>) {
      _isOnline = initResult.contains(ConnectivityResult.mobile) || 
                  initResult.contains(ConnectivityResult.wifi) ||
                  initResult.contains(ConnectivityResult.ethernet);
    } else {
       _isOnline = initResult == ConnectivityResult.mobile || 
                   initResult == ConnectivityResult.wifi || 
                   initResult == ConnectivityResult.ethernet;
    }

    // 2. Prepare Offline File
    await _prepareOfflineFile();
    await _prepareVietMapOfflineFile();
    
    _isInitialized = true;
    debugPrint('✅ OfflineMapService initialized (Online: $_isOnline)');
  }
  
  /// Copy file từ assets ra storage
  Future<void> _prepareOfflineFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_bundledFileName');
      
      // Load asset trước để lấy kích thước
      final data = await rootBundle.load('assets/$_bundledFileName');
      final bytes = data.buffer.asUint8List();
      
      bool shouldUpdate = false;
      
      if (await file.exists()) {
        final localSize = await file.length();
        final assetSize = bytes.length;
        debugPrint('📂 Local Map: ${localSize} bytes | Asset Map: ${assetSize} bytes');
        
        if (localSize != assetSize) {
          debugPrint('🔄 Phát hiện bản đồ mới! Đang cập nhật...');
          shouldUpdate = true;
        }
      } else {
        shouldUpdate = true;
      }

      if (shouldUpdate) {
         try {
          await file.writeAsBytes(bytes, flush: true);
          debugPrint('✅ Đã copy xong bản đồ offline: ${file.path}');
        } catch (e) {
          debugPrint('⚠️ Lỗi khi ghi file map: $e');
          return;
        }
      } else {
        debugPrint('✅ Bản đồ offline đã mới nhất.');
      }



      // Khởi tạo Provider
      try {
        // Mở file mbtiles
        final mbtiles = MbTiles(mbtilesPath: file.path);
        
        // Tạo provider từ object mbtiles
        _offlineProvider = MbTilesTileProvider(
          mbtiles: mbtiles, 
          silenceTileNotFound: true,
        );
      } catch (e) {
        debugPrint('❌ Lỗi khởi tạo MbTilesProvider: $e');
      }
      
    } catch (e) {
      debugPrint('❌ Lỗi prepare offline file: $e');
    }
  }

  /// Prepare VietMap offline file
  Future<void> _prepareVietMapOfflineFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_vietmapFileName');
      
      // Load asset
      final data = await rootBundle.load('assets/$_vietmapFileName');
      final bytes = data.buffer.asUint8List();
      
      bool shouldUpdate = false;
      
      if (await file.exists()) {
        final localSize = await file.length();
        final assetSize = bytes.length;
        debugPrint('📂 VietMap Local: ${localSize} bytes | Asset: ${assetSize} bytes');
        
        if (localSize != assetSize) {
          debugPrint('🔄 Phát hiện VietMap tiles mới! Đang cập nhật...');
          shouldUpdate = true;
        }
      } else {
        shouldUpdate = true;
      }

      if (shouldUpdate) {
        try {
          await file.writeAsBytes(bytes, flush: true);
          debugPrint('✅ Đã copy xong VietMap offline: ${file.path}');
        } catch (e) {
          debugPrint('⚠️ Lỗi khi ghi file VietMap: $e');
          return;
        }
      } else {
        debugPrint('✅ VietMap offline đã mới nhất.');
      }

      // Khởi tạo Provider
      try {
        final mbtiles = MbTiles(mbtilesPath: file.path);
        _vietmapOfflineProvider = MbTilesTileProvider(
          mbtiles: mbtiles, 
          silenceTileNotFound: true,
        );
        debugPrint('✅ VietMap offline provider initialized');
      } catch (e) {
        debugPrint('❌ Lỗi khởi tạo VietMap Provider: $e');
      }
      
    } catch (e) {
      debugPrint('⚠️ VietMap offline không có sẵn: $e');
    }
  }

  /// Lấy TileProvider phù hợp dựa trên trạng thái mạng
  TileProvider getTileProvider({
    String urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  }) {
    // Logic: 
    // - Nếu có mạng: Dùng Network (ưu tiên)
    // - Nếu mất mạng: Dùng Offline (nếu có provider)
    
    if (_isOnline) {
      return NetworkTileProvider(); 
      // Có thể dùng FMTC nếu muốn cache thêm
    } else {
      if (_offlineProvider != null) {
        return _offlineProvider!;
      } else {
        // Fallback nếu không có file offline
        return NetworkTileProvider();
      }
    }
  }
  
  bool get isOnline => _isOnline;
  bool get hasOfflineMap => _offlineProvider != null;
  bool get hasVietMapOffline => _vietmapOfflineProvider != null;
  
  /// Lấy VietMap offline provider (nếu có)
  TileProvider? get vietmapOfflineProvider => _vietmapOfflineProvider;
  
  void dispose() {
    _networkStatusController.close();
    _offlineProvider?.dispose();
  }
}
