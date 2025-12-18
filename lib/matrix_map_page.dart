import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'main_navigation.dart'; // Import để truy cập MainNavigationState
import 'data/vn_boundaries.dart'; // Ranh giới tỉnh VN từ assets
import 'data/vn_roads.dart'; // Quốc lộ & Cao tốc VN từ assets
import 'widgets/import_data_dialog.dart'; // Dialog import/export dữ liệu
import 'services/offline_map_service.dart'; // Offline map caching
import 'services/vietmap_service.dart'; // VietMap API service

const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

// --- MODEL DỮ LIỆU ---
class RoadData {
  final String id;
  final String name;
  final String ref;
  final String type; // 'motorway', 'trunk', 'boundary'
  final List<LatLng> points;
  final int colorValue;
  final double width;
  final bool isMaritime; // Đánh dấu biên giới biển

  RoadData({
    required this.id,
    required this.name,
    required this.ref,
    required this.type,
    required this.points,
    required this.colorValue,
    required this.width,
    this.isMaritime = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ref': ref,
    'type': type,
    'color': colorValue,
    'width': width,
    'isMaritime': isMaritime,
    'points': points
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
  };

  factory RoadData.fromJson(Map<String, dynamic> json) {
    return RoadData(
      id: json['id'],
      name: json['name'],
      ref: json['ref'],
      type: json['type'],
      colorValue: json['color'],
      width: json['width'],
      isMaritime: json['isMaritime'] ?? false,
      points: (json['points'] as List)
          .map((p) => LatLng(p['lat'], p['lng']))
          .toList(),
    );
  }
}

// --- LAYER DATA STRUCTURES ---
class LayerItem {
  final String id;
  final String name;
  final String type; // 'boundary', 'road'
  bool isVisible;
  final List<Polyline> polylines;

  LayerItem({
    required this.id,
    required this.name,
    required this.type,
    this.isVisible = false,
    required this.polylines,
  });
}

class LayerGroup {
  final String name;
  final List<LayerItem> items;
  bool isExpanded;

  LayerGroup({
    required this.name,
    required this.items,
    this.isExpanded = false,
  });
}

class MatrixMapPage extends StatefulWidget {
  const MatrixMapPage({Key? key}) : super(key: key);

  @override
  State<MatrixMapPage> createState() => MatrixMapPageState();
}

enum MapType {
  google,
  satellite,
  osm,
  vietmap
}

/// Nguồn tìm kiếm dữ liệu đường
enum SearchSource {
  offline,  // Dữ liệu offline (assets + cache)
  osm,      // OpenStreetMap Overpass API
}

/// State public để MainNavigation có thể lấy lastSelectedLayerName
class MatrixMapPageState extends State<MatrixMapPage> {
  // --- CONTROLLER ---
  final TextEditingController _widthCtrl = TextEditingController(text: "600");
  final TextEditingController _heightCtrl = TextEditingController(text: "700");
  final TextEditingController _searchCtrl = TextEditingController();
  final MapController _mapController = MapController();
  
  // State
  MapType _currentMapType = MapType.google; // Mặc định dùng Google cho sạch
  double _renderWidth = 600;
  double _renderHeight = 700;
  int _selectedTileSize = 50;

  List<Polyline> _kmzPolylines = [];
  List<RoadData> _cachedRoads = [];
  List<Polyline> _displayedPolylines = [];
  bool _hasRoadSelected = false; // [MỚI] Giữ nút DÒ BIT hiển thị khi đường nháy

  // Layer Tree Data
  List<LayerGroup> _layerGroups = [];
  bool _showLayerPanel = true;
  Set<String> _selectedLayerIds = {}; // IDs của các layer đang được bật
  
  /// PUBLIC: Tên layer cuối cùng được chọn (để truyền sang Scanner)
  String? lastSelectedLayerName;

  List<Polygon> _gridPolygons = [];
  List<Marker> _gridMarkers = [];
  LatLngBounds? _currentBounds;

  // Lưu trữ ID của từng tấm. Key: "A1", Value: "26"
  // Dùng để map giữa tọa độ lưới và ID phần cứng
  Map<String, String> _tileControlIds = {};

  // Đường do người dùng thêm thủ công vào panel
  // Key: Tên chuẩn (VD: "QL1", "CT.01"), Value: polylines đã vẽ
  Map<String, List<Polyline>> _manualAddedRoads = {};

  // UI Loading State
  String? _loadingStatus;

  bool _showGrid = true;
  bool _isMapReady = false;


  // Tùy chọn tìm kiếm - Nguồn dữ liệu
  SearchSource _searchSource = SearchSource.offline;
  
  bool _useMerged2025 = false; // Sử dụng dữ liệu 34 tỉnh 2025 (sau sáp nhập)

  // [MỚI] Cache kết quả tìm kiếm online
  // Key: từ khóa đã chuẩn hóa (uppercase), Value: polylines đã tìm được
  final Map<String, List<Polyline>> _searchCache = {};
  
  // [MỚI] Lịch sử tìm kiếm (từ khóa đã tìm, mới nhất ở đầu)
  List<String> _searchHistory = [];

  // VietMap Tilemap API Key
  static const String _vietmapApiKey = 'dd90b70f3100c8b3cf5f0e0818b323492f7e15f9697ab44b';

  // Helper lấy URL Tile
  String _getTileUrl() {
    switch (_currentMapType) {
      case MapType.google:
        return 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}'; // Google Road Map
      case MapType.satellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case MapType.osm:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case MapType.vietmap:
        return 'https://maps.vietmap.vn/api/tm/{z}/{x}/{y}@2x.png?apikey=$_vietmapApiKey';
    }
  }

  // Lấy tên hiển thị cho loại bản đồ
  String _getMapTypeName() {
    switch (_currentMapType) {
      case MapType.google:
        return 'Google';
      case MapType.satellite:
        return 'Vệ tinh';
      case MapType.osm:
        return 'OSM';
      case MapType.vietmap:
        return 'VietMap';
    }
  }

  // Helper check Grid Colors
  Color get _gridColor => (_currentMapType == MapType.satellite) ? Colors.white : Colors.blue;

  LatLng _savedCenter = const LatLng(21.0285, 105.8542);
  double _savedZoom = 10.0;

  int get cols => (_renderWidth / _selectedTileSize).ceil();
  int get rows => (_renderHeight / _selectedTileSize).ceil();

  @override
  void initState() {
    super.initState();
    _loadAllSettings();
    _loadCachedRoadsFromFile();
    
    // [MỚI] Preload dữ liệu đường ở background để tránh treo UI khi gợi ý
    Future.microtask(() async {
      await RoadAssetService().loadFromAssets();
      debugPrint("✅ Preloaded ${RoadAssetService().count} tuyến đường cho gợi ý");
    });
  }

  // --- SETTINGS (CẬP NHẬT ĐỂ LƯU THÊM ID TẤM) ---
  Future<void> _loadAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _widthCtrl.text = prefs.getString('map_width') ?? "600";
      _heightCtrl.text = prefs.getString('map_height') ?? "700";
      _renderWidth = double.tryParse(_widthCtrl.text) ?? 600;
      _renderHeight = double.tryParse(_heightCtrl.text) ?? 700;
      _selectedTileSize = prefs.getInt('map_tile_size') ?? 50;
      _selectedTileSize = prefs.getInt('map_tile_size') ?? 50;
      
      // Load Map Type (Migrate từ _isSatelliteMode cũ)
      int mapTypeIndex = prefs.getInt('map_type_index') ?? 0;
      if (prefs.containsKey('map_satellite_mode')) {
        bool oldSatMode = prefs.getBool('map_satellite_mode') ?? false;
        if (oldSatMode) mapTypeIndex = MapType.satellite.index;
      }
      _currentMapType = MapType.values.elementAtOrNull(mapTypeIndex) ?? MapType.google;
      _useMerged2025 = prefs.getBool('map_use_merged_2025') ?? false;

      // [MỚI] Load lịch sử tìm kiếm
      String? historyJson = prefs.getString('search_history');
      if (historyJson != null) {
        _searchHistory = List<String>.from(jsonDecode(historyJson));
      }

      // Load ID các tấm đã lưu
      String? tileIdsJson = prefs.getString('map_tile_ids');
      if (tileIdsJson != null) {
        _tileControlIds = Map<String, String>.from(jsonDecode(tileIdsJson));
      }

      double lat = prefs.getDouble('map_center_lat') ?? 21.0285;
      double lng = prefs.getDouble('map_center_lng') ?? 105.8542;
      _savedCenter = LatLng(lat, lng);
      _savedZoom = prefs.getDouble('map_zoom') ?? 10.0;

      if (prefs.containsKey('kmz_min_lat')) {
        double minLat = prefs.getDouble('kmz_min_lat')!;
        double maxLat = prefs.getDouble('kmz_max_lat')!;
        double minLng = prefs.getDouble('kmz_min_lng')!;
        double maxLng = prefs.getDouble('kmz_max_lng')!;
        _currentBounds = LatLngBounds(
          LatLng(minLat, minLng),
          LatLng(maxLat, maxLng),
        );
        
        // [FIX] Tạo placeholder polyline để nút "Xóa KMZ" hiển thị
        _kmzPolylines = [
          Polyline(
            points: [
              LatLng(minLat, minLng),
              LatLng(minLat, maxLng),
              LatLng(maxLat, maxLng),
              LatLng(maxLat, minLng),
              LatLng(minLat, minLng),
            ],
            color: (_currentMapType == MapType.satellite) ? Colors.cyanAccent : Colors.black,
            strokeWidth: 2,
            isDotted: true,
          ),
        ];
        
        // [TỐI ƯU] Delay vẽ lưới để map load xong trước
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted && _currentBounds != null) {
             _generateGridOnMap(_currentBounds!);
          }
        });
      }
    });
  }

  Future<void> _saveAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('map_width', _widthCtrl.text);
    await prefs.setString('map_height', _heightCtrl.text);
    await prefs.setInt('map_tile_size', _selectedTileSize);
    await prefs.setInt('map_tile_size', _selectedTileSize);
    await prefs.setInt('map_type_index', _currentMapType.index);
    await prefs.setBool('map_use_merged_2025', _useMerged2025);

    // Lưu ID các tấm
    await prefs.setString('map_tile_ids', jsonEncode(_tileControlIds));

    // [MỚI] Lưu lịch sử tìm kiếm (giới hạn 20)
    if (_searchHistory.length > 20) {
      _searchHistory = _searchHistory.sublist(0, 20);
    }
    await prefs.setString('search_history', jsonEncode(_searchHistory));

    if (_isMapReady) {
      await prefs.setDouble(
        'map_center_lat',
        _mapController.camera.center.latitude,
      );
      await prefs.setDouble(
        'map_center_lng',
        _mapController.camera.center.longitude,
      );
      await prefs.setDouble('map_zoom', _mapController.camera.zoom);
    }

    if (_currentBounds != null) {
      await prefs.setDouble('kmz_min_lat', _currentBounds!.south);
      await prefs.setDouble('kmz_max_lat', _currentBounds!.north);
      await prefs.setDouble('kmz_min_lng', _currentBounds!.west);
      await prefs.setDouble('kmz_max_lng', _currentBounds!.east);
    }
  }

  // --- FILE SYSTEM ---
  Future<void> _saveCachedRoadsToFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/idmav_roads.json');
      String jsonStr = jsonEncode(_cachedRoads.map((e) => e.toJson()).toList());
      await file.writeAsString(jsonStr);
      debugPrint("Đã lưu tổng cộng: ${_cachedRoads.length} items");
    } catch (e) {
      debugPrint("Lỗi lưu file: $e");
    }
  }

  Future<void> _loadCachedRoadsFromFile() async {
    // 1. Load Cached Roads (Ranh giới, vùng...)
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/idmav_roads.json');
      if (await file.exists()) {
        String jsonStr = await file.readAsString();
        List<dynamic> jsonList = jsonDecode(jsonStr);
        setState(() {
          _cachedRoads = jsonList.map((e) => RoadData.fromJson(e)).toList();
        });
        debugPrint("✅ Đã load ${_cachedRoads.length} cached roads");
      }
    } catch (e) {
      debugPrint("Lỗi load cached roads: $e");
      // Không return, vẫn tiếp tục load manual roads
    }

    // 2. Load Manual Roads (Đường thủ công - user thêm vào panel)
    await _loadManualRoadsFromFile();
    
    // 3. Populate Groups
    if (mounted) {
      setState(() {
         _populateLayerGroups(); 
      });
    }
  }

  // Lưu đường thủ công vào file
  Future<void> _saveManualRoadsToFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/idmav_manual_roads.json');
      
      // Convert polylines to storable format
      Map<String, dynamic> dataToSave = {};
      _manualAddedRoads.forEach((name, polylines) {
        dataToSave[name] = polylines.map((p) => {
          'points': p.points.map((pt) => {'lat': pt.latitude, 'lng': pt.longitude}).toList(),
          'color': p.color.value,
          'width': p.strokeWidth,
          'isDotted': p.isDotted,
        }).toList();
      });
      
      await file.writeAsString(jsonEncode(dataToSave));
      debugPrint("✅ Đã lưu ${_manualAddedRoads.length} đường thủ công");
    } catch (e) {
      debugPrint("Lỗi lưu đường thủ công: $e");
    }
  }

  // Load đường thủ công từ file
  Future<void> _loadManualRoadsFromFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/idmav_manual_roads.json');
      if (await file.exists()) {
        String jsonStr = await file.readAsString();
        Map<String, dynamic> data = jsonDecode(jsonStr);
        
        _manualAddedRoads.clear();
        data.forEach((name, polylinesData) {
          List<Polyline> polylines = (polylinesData as List).map((pData) {
            List<LatLng> points = (pData['points'] as List)
                .map((pt) => LatLng(pt['lat'], pt['lng']))
                .toList();
            return Polyline(
              points: points,
              color: Color(pData['color']),
              strokeWidth: (pData['width'] as num).toDouble(),
              isDotted: pData['isDotted'] ?? false,
            );
          }).toList();
          
          _manualAddedRoads[name] = polylines;
          // [KHÔNG auto tick] - User sẽ tự tick nếu cần hiển thị
        });
        
        debugPrint("✅ Đã load ${_manualAddedRoads.length} đường thủ công");
      }
    } catch (e) {
      debugPrint("Lỗi load đường thủ công: $e");
    }
  }

  // --- LAYER TREE METHODS ---
  /// Populate layer groups từ cached roads
  void _populateLayerGroups() {
    // NHÓM 1: Biên giới Việt Nam (Quốc gia) - BỎ QUA biên giới biển
    List<LayerItem> borderItems = [];
    Set<String> addedBorders = {};
    for (var road in _cachedRoads) {
      if (road.type == 'boundary') {
        // Bỏ qua biên giới biển (theo tên)
        if (_isMaritimeBoundary(road.name)) continue;
        
        // Tìm ranh giới quốc gia (thường chứa "Việt Nam" hoặc là admin_level 2)
        String lowerName = road.name.toLowerCase();
        if (lowerName.contains('việt nam') || lowerName.contains('vietnam')) {
          if (!addedBorders.contains('vietnam')) {
            borderItems.add(LayerItem(
              id: 'border_vietnam',
              name: 'Biên giới Việt Nam',
              type: 'boundary',
              isVisible: _selectedLayerIds.contains('border_vietnam'),
              polylines: [],
            ));
            addedBorders.add('vietnam');
          }
        }
      }
    }

    // NHÓM 2: Ranh giới tỉnh/thành (unique by name) - BỎ QUA biên giới biển
    Map<String, RoadData> boundaryMap = {};
    for (var road in _cachedRoads) {
      if (road.type == 'boundary' && road.name.isNotEmpty) {
        // Bỏ qua biên giới biển (theo tên)
        if (_isMaritimeBoundary(road.name)) continue;
        
        String lowerName = road.name.toLowerCase();
        // Bỏ qua biên giới quốc gia
        if (lowerName.contains('việt nam') || lowerName.contains('vietnam')) continue;
        if (!boundaryMap.containsKey(road.name)) {
          boundaryMap[road.name] = road;
        }
      }
    }

    List<LayerItem> boundaryItems = boundaryMap.entries.map((e) {
      return LayerItem(
        id: 'boundary_${e.key}',
        name: e.key,
        type: 'boundary',
        isVisible: _selectedLayerIds.contains('boundary_${e.key}'),
        polylines: [],
      );
    }).toList();
    boundaryItems.sort((a, b) => a.name.compareTo(b.name));

    // NHÓM 3: Quốc lộ & Cao tốc - Tên chuẩn từ search (KHÔNG tự động)
    // Chỉ hiển thị các đường từ _manualAddedRoads (người dùng thêm thủ công)
    List<LayerItem> roadItems = _manualAddedRoads.entries.map((e) {
      return LayerItem(
        id: 'road_${e.key}',
        name: e.key, // Tên đã chuẩn hóa (VD: QL1, CT.01)
        type: 'road',
        isVisible: _selectedLayerIds.contains('road_${e.key}'),
        polylines: [],
      );
    }).toList();
    roadItems.sort((a, b) => a.name.compareTo(b.name));

    setState(() {
      _layerGroups = [
        LayerGroup(
          name: 'Quốc gia',
          items: borderItems,
          isExpanded: false,
        ),
        LayerGroup(
          name: 'Tỉnh/TP',
          items: boundaryItems,
          isExpanded: false,
        ),
        LayerGroup(
          name: 'Quốc lộ',
          items: roadItems,
          isExpanded: roadItems.isNotEmpty,
        ),
      ];
    });
  }

  // [MỚI] Kiểm tra biên giới biển theo tên
  bool _isMaritimeBoundary(String name) {
    String lower = name.toLowerCase();
    // Các từ khóa biên giới biển
    List<String> maritimeKeywords = [
      'biển', 'sea', 'maritime', 'ocean',
      'hoàng sa', 'trường sa', 'paracel', 'spratly',
      'vùng đặc quyền', 'exclusive economic zone',
    ];
    for (var keyword in maritimeKeywords) {
      if (lower.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

  /// Toggle hiển thị một layer
  void _onLayerToggled(String layerId, bool isVisible) {
    setState(() {
      if (isVisible) {
        _selectedLayerIds.add(layerId);
        // Lưu tên layer để truyền sang Scanner
        // Lấy tên từ layerId (bỏ prefix boundary_, road_, border_)
        if (layerId.startsWith('boundary_')) {
          lastSelectedLayerName = layerId.replaceFirst('boundary_', '');
        } else if (layerId.startsWith('road_')) {
          lastSelectedLayerName = layerId.replaceFirst('road_', '');
        } else if (layerId == 'border_vietnam') {
          lastSelectedLayerName = 'Biên giới Việt Nam';
        }
      } else {
        _selectedLayerIds.remove(layerId);
      }
    });
    // Truyền layerId vừa chọn để camera bay tới layer đó (không phải tất cả)
    _updateDisplayedPolylinesFromLayers(flyToLayerId: isVisible ? layerId : null);
  }

  /// Toggle hiển thị cả nhóm
  void _onGroupToggled(LayerGroup group, bool isVisible) {
    setState(() {
      for (var item in group.items) {
        if (isVisible) {
          _selectedLayerIds.add(item.id);
        } else {
          _selectedLayerIds.remove(item.id);
        }
        item.isVisible = isVisible;
      }
    });
    // Không bay camera khi toggle cả nhóm
    _updateDisplayedPolylinesFromLayers(flyToLayerId: null);
  }


  /// Cập nhật polylines hiển thị dựa trên layers đã chọn
  /// flyToLayerId: nếu không null, chỉ bay camera tới layer này
  void _updateDisplayedPolylinesFromLayers({String? flyToLayerId}) {
    List<Polyline> newPolylines = [];
    List<Polyline> flyToPolylines = []; // Polylines của layer vừa chọn
    
    for (var layerId in _selectedLayerIds) {
      List<Polyline> layerPolylines = [];
      
      // Xử lý Biên giới Việt Nam
      if (layerId == 'border_vietnam') {
        for (var road in _cachedRoads) {
          if (road.type == 'boundary') {
            String lowerName = road.name.toLowerCase();
            if (lowerName.contains('việt nam') || lowerName.contains('vietnam')) {
              // Bỏ qua biên giới biển theo tên
              if (_isMaritimeBoundary(road.name)) continue;
              
              List<LatLng> renderPoints = _simplifyForRendering(road.points);
              layerPolylines.add(
                Polyline(
                  points: renderPoints,
                  color: Colors.deepPurple,
                  strokeWidth: 5.0,
                  isDotted: true,
                ),
              );
            }
          }
        }
      }
      // Xử lý Ranh giới tỉnh/thành
      else if (layerId.startsWith('boundary_')) {
        String name = layerId.replaceFirst('boundary_', '');
        for (var road in _cachedRoads) {
          if (road.type == 'boundary' && road.name == name) {
            // Bỏ qua biên giới biển theo tên
            if (_isMaritimeBoundary(road.name)) continue;
            
            List<LatLng> renderPoints = _simplifyForRendering(road.points);
            layerPolylines.add(
              Polyline(
                points: renderPoints,
                color: Colors.purpleAccent,
                strokeWidth: 4.0,
                isDotted: true,
              ),
            );
          }
        }
      } 
      // Xử lý Quốc lộ/Cao tốc - Lấy polylines đã lưu
      else if (layerId.startsWith('road_')) {
        String roadName = layerId.replaceFirst('road_', '');
        // Lấy polylines đã lưu trong _manualAddedRoads
        if (_manualAddedRoads.containsKey(roadName)) {
          layerPolylines.addAll(_manualAddedRoads[roadName]!);
        }
      }
      
      newPolylines.addAll(layerPolylines);
      
      // Nếu đây là layer vừa được chọn, lưu để bay tới
      if (flyToLayerId != null && layerId == flyToLayerId) {
        flyToPolylines = layerPolylines;
      }
    }

    setState(() {
      _displayedPolylines = newPolylines;
      _hasRoadSelected = newPolylines.isNotEmpty; // Cập nhật trạng thái nút DÒ BIT
    });

    // [DISABLED] Không tự động bay camera khi toggle layer
    // Người dùng không muốn camera tự động di chuyển
    if (flyToPolylines.isNotEmpty) {
      _fitCameraToPolylines(flyToPolylines, zoom: 8);
    }
  }


  Future<void> _clearAllData() async {
    try {
      setState(() {
        _cachedRoads.clear();  // Xóa ranh giới/đường đã cache
        RoadAssetService().clearCache(); // [MỚI] Reset cache Roads Service
        _displayedPolylines.clear();  // Xóa polylines đang hiển thị
        _hasRoadSelected = false; // Ẩn nút DÒ BIT
        _manualAddedRoads.clear();  // Xóa đường thủ công
        _selectedLayerIds.clear();  // Xóa selected layers
        // KHÔNG xóa KMZ, grid, bounds - giữ nguyên khung lưới
      });
      
      // Xóa file cache roads
      final directory = await getApplicationDocumentsDirectory();
      final roadFile = File('${directory.path}/idmav_roads.json');
      if (await roadFile.exists()) await roadFile.delete();
      final manualFile = File('${directory.path}/idmav_manual_roads.json');
      if (await manualFile.exists()) await manualFile.delete();
      
      // Cập nhật Layer Panel
      _populateLayerGroups();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Đã xóa dữ liệu đường/ranh giới! (Giữ nguyên lưới KMZ)")),
      );
    } catch (e) {
      debugPrint("Lỗi xóa: $e");
    }
  }

  /// [MỚI] Xóa đường khỏi panel và cập nhật hiển thị
  Future<void> _deleteRoadFromPanel(String roadName) async {
    setState(() {
      // Xóa khỏi danh sách đường thủ công
      _manualAddedRoads.remove(roadName);
      
      // Xóa khỏi selected layers nếu đang được chọn
      String layerId = 'road_$roadName';
      _selectedLayerIds.remove(layerId);
    });
    
    // Lưu lại file
    await _saveManualRoadsToFile();
    
    // Cập nhật lại layer panel
    _populateLayerGroups();
    
    // Cập nhật lại polylines hiển thị (xóa đường vừa xóa khỏi bản đồ)
    _updateDisplayedPolylinesFromLayers(flyToLayerId: null);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Đã xóa \"$roadName\" khỏi danh sách!"),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  // --- RACE TO FIND SERVER ---
  Future<http.Response> _raceToFindServer(List<String> urls, String query) {
    final completer = Completer<http.Response>();
    int failureCount = 0;
    for (var url in urls) {
      http
          .post(Uri.parse(url), body: query)
          .timeout(const Duration(seconds: 40))
          .then((response) {
            if (!completer.isCompleted && response.statusCode == 200) {
              debugPrint("✅ SERVER THÀNH CÔNG: $url");
              completer.complete(response);
            }
            else {
              failureCount++;
              if (failureCount == urls.length && !completer.isCompleted)
                completer.completeError("Tất cả Server đều lỗi");
            }
          })
          .catchError((e) {
            failureCount++;
            if (failureCount == urls.length && !completer.isCompleted)
              completer.completeError(e);
          });
    }
    return completer.future;
  }

  // --- CREATE SUPER FLEXIBLE REGEX ---
  String _createSuperFlexibleRegex(String input) {
    String clean = input.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (clean.isEmpty) return input;
    List<String> chars = clean.split('');
    String core = chars.join(r'[.\\-\\s]*');
    return '(^|[^a-zA-Z0-9])$core(\$|[^a-zA-Z0-9])';
  }

  // --- HELPER FUNCTIONS ---
  List<LatLng> _simplifyPoints(
    List<LatLng> input, {
    double threshold = 0.0005,
  }) {
    if (input.length < 3) return input;
    List<LatLng> result = [input.first];
    for (int i = 1; i < input.length - 1; i++) {
      double dx = input[i].latitude - result.last.latitude;
      double dy = input[i].longitude - result.last.longitude;
      if (dx * dx + dy * dy > threshold * threshold) result.add(input[i]);
    }
    result.add(input.last);
    return result;
  }

  List<LatLng> _simplifyForRendering(List<LatLng> points) {
    if (!_isMapReady) return points;
    double zoom = _mapController.camera.zoom;
    double threshold;
    if (zoom < 12)
      threshold = 0.002;
    else if (zoom < 14)
      threshold = 0.001;
    else if (zoom < 16)
      threshold = 0.0005;
    else
      threshold = 0.0002;
    return _simplifyPoints(points, threshold: threshold);
  }

  void _fitCameraToPolylines(List<Polyline> polylines, {double zoom = 8.0, double latOffset = 1}) {
    if (polylines.isEmpty) return;
    double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    bool hasPoints = false;
    for (var line in polylines) {
      for (var p in line.points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
        hasPoints = true;
      }
    }
    if (hasPoints) {
      double latDiff = (maxLat - minLat).abs();
      double lngDiff = (maxLng - minLng).abs();

      // Nếu vùng bao phủ lớn (trên 0.05 độ ~ 5km) -> Fit Bounds để thấy hết 2 đầu
      if (latDiff > 0.05 || lngDiff > 0.05) {
        // Tính toán bounds
        LatLngBounds bounds = LatLngBounds(
          LatLng(minLat, minLng),
          LatLng(maxLat, maxLng),
        );
        
        // Fit camera vào khung với padding, quay về hướng Bắc
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.all(50),
          )
        );
        _mapController.rotate(0); 
      } else {
        // Đối tượng nhỏ -> Bay tới tâm và zoom vào (logic cũ)
        LatLng center = LatLng(
          (minLat + maxLat) / 2 - latOffset, // Offset tránh panel
          (minLng + maxLng) / 2,
        );
        _mapController.move(center, zoom);
        _mapController.rotate(0);
      }
    }
  }


  // Fit camera vào ranh giới với offset cao hơn để tránh panel
  void _fitCameraToBoundariesWithOffset(List<Polyline> polylines) {
    if (polylines.isEmpty) return;
    double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    bool hasPoints = false;
    for (var line in polylines) {
      for (var p in line.points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
        hasPoints = true;
      }
    }
    if (hasPoints && mounted) {
      LatLngBounds bounds = LatLngBounds(
        LatLng(minLat, minLng),
        LatLng(maxLat, maxLng),
      );
      // Delay ngắn để đảm bảo map đã ready
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          debugPrint("🎯 Fit camera to bounds: $bounds");
          _mapController.fitCamera(
            CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.only(
              left: 200, // Panel width
              top: 100,  
              right: 20,
              bottom: 60,
            )),
          );
        }
      });
    }
  }



  Future<void> _mergeAndSave(List<RoadData> newItems, String label) async {
    if (newItems.isEmpty) {
      if (label.contains("Import"))
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("File Import không có dữ liệu hợp lệ!")),
        );
      return;
    }
    Set<String> existingIds = _cachedRoads.map((e) => e.id).toSet();
    List<RoadData> itemsToAdd = [];
    int duplicateCount = 0;
    for (var item in newItems) {
      if (!existingIds.contains(item.id)) {
        itemsToAdd.add(item);
        existingIds.add(item.id);
      } else {
        duplicateCount++;
      }
    }
    if (itemsToAdd.isNotEmpty) {
      setState(() {
        _cachedRoads.addAll(itemsToAdd);
      });
      await _saveCachedRoadsToFile();
      
      // Cập nhật layer panel nếu có ranh giới mới
      bool hasBoundaries = itemsToAdd.any((item) => item.type == 'boundary');
      if (hasBoundaries) {
        _populateLayerGroups();
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "✅ Đã thêm ${itemsToAdd.length} $label mới (Bỏ qua $duplicateCount trùng)",
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Dữ liệu $label này đã có sẵn!"),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  // --- [MỚI] TỰ ĐỘNG PHÁT HIỆN CÁC TỈNH TRONG KHU VỰC KMZ ---
  // Ưu tiên đọc từ ASSETS (nhanh, offline) → Fallback về API nếu cần
  void _autoDetectProvincesFromKMZ(LatLngBounds bounds, {bool skipFitCamera = false}) {
    // Kiểm tra nếu đã có dữ liệu ranh giới tỉnh thì không tải lại
    int existingBoundaries = _cachedRoads.where((r) => r.type == 'boundary').length;
    if (existingBoundaries > 0) {
      debugPrint("⚠️ Đã có $existingBoundaries ranh giới trong cache, bỏ qua tải lại");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Đã có $existingBoundaries ranh giới trong cache"),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    
    // Chạy hoàn toàn ngầm
    Future.microtask(() async {
      try {
        debugPrint("📍 Bắt đầu tìm tỉnh trong KMZ bounds (từ assets)...");
        
        // --- ƯU TIÊN ĐỌC TỪ ASSETS ---
        final boundaryService = BoundaryAssetService();
        
        // Chọn version dữ liệu dựa trên tùy chọn người dùng
        boundaryService.currentVersion = _useMerged2025 
            ? BoundaryDataVersion.merged34 
            : BoundaryDataVersion.current63;
        
        String versionName = _useMerged2025 ? "34 tỉnh 2025" : "63 tỉnh";
        debugPrint("📦 Sử dụng dữ liệu: $versionName");
        
        bool assetsLoaded = await boundaryService.loadFromAssets();
        
        if (assetsLoaded) {
          // Tìm các tỉnh giao với bounds
          List<VnBoundaryData> matchedBoundaries = boundaryService.findBoundariesInBounds(bounds);
          
          debugPrint("✅ Assets: Tìm thấy ${matchedBoundaries.length} ranh giới trong bounds");
          
          if (matchedBoundaries.isNotEmpty) {
            List<RoadData> allBoundaries = [];
            
            for (var boundary in matchedBoundaries) {
              // Chuyển mỗi polygon thành RoadData
              // (Dữ liệu đã được lọc biển sẵn trong file assets)
              int segmentIndex = 0;
              for (var polygon in boundary.polygons) {
                if (polygon.length < 2) continue;
                
                // Clip polygon nếu cần
                List<LatLng> clippedPoints = _clipPointsToBounds(polygon, bounds);
                if (clippedPoints.length < 2) continue;
                
                // Simplify để tối ưu hiệu năng
                List<LatLng> simplified = _simplifyPoints(clippedPoints, threshold: 0.0005);
                
                allBoundaries.add(RoadData(
                  id: '${boundary.name}_$segmentIndex',
                  name: boundary.name,
                  ref: boundary.type == 'country' ? 'VN' : '${boundary.name}',
                  type: 'boundary',
                  points: simplified,
                  colorValue: boundary.type == 'country' 
                      ? Colors.deepPurpleAccent.value 
                      : Colors.purpleAccent.value,
                  width: boundary.type == 'country' ? 4.0 : 3.0,
                  isMaritime: false, // Đã lọc sẵn trong file
                ));
                segmentIndex++;
              }
            }
            
            // Merge và cập nhật UI
            if (allBoundaries.isNotEmpty && mounted) {
              await _mergeAndSave(allBoundaries, "Ranh giới từ assets");
              
              if (mounted) {
                setState(() {
                  _populateLayerGroups();
                });
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text("✅ Đã tải ${matchedBoundaries.length} ranh giới từ assets"),
                    backgroundColor: Colors.green,
                    duration: const Duration(seconds: 2),
                  ),
                );
                
                // Fit camera vào vùng ranh giới (chỉ khi không skip)
                if (!skipFitCamera) {
                  List<Polyline> boundaryPolylines = allBoundaries.map((b) => 
                    Polyline(points: b.points, color: Colors.purple)
                  ).toList();
                  _fitCameraToBoundariesWithOffset(boundaryPolylines);
                }
              }
              
              debugPrint("✅ Đã tải xong ${allBoundaries.length} đoạn ranh giới từ assets");
              return; // Hoàn thành - không cần fallback API
            }
          }
        }
        
        // --- FALLBACK: GỌI API NẾU ASSETS KHÔNG CÓ DỮ LIỆU ---
        debugPrint("⚠️ Không tìm thấy trong assets, fallback về API...");
        await _autoDetectProvincesFromAPI(bounds);
        
      } catch (e) {
        debugPrint("Lỗi auto-detect provinces: $e");
      }
    });
  }

  // (Maritime detection đã được xử lý trong file assets - không cần runtime detection)

  // Clip một list LatLng vào trong bounds
  List<LatLng> _clipPointsToBounds(List<LatLng> points, LatLngBounds bounds) {
    List<LatLng> result = [];
    for (var point in points) {
      if (bounds.contains(point)) {
        result.add(point);
      } else if (result.isNotEmpty) {
        // Nếu điểm trước đó trong bounds, thêm điểm giao
        // Đơn giản hóa: thêm điểm gần biên nhất
        result.add(LatLng(
          point.latitude.clamp(bounds.south, bounds.north),
          point.longitude.clamp(bounds.west, bounds.east),
        ));
      }
    }
    return result;
  }

  // Fallback: Tải ranh giới từ API (giữ nguyên logic cũ)
  Future<void> _autoDetectProvincesFromAPI(LatLngBounds bounds) async {
    debugPrint("📍 Fallback: Tải ranh giới từ API...");
    
    String bbox = '${bounds.south},${bounds.west},${bounds.north},${bounds.east}';
    String query = """
      [out:json][timeout:30];
      area(3600049915)->.vn;
      (
        relation["boundary"="administrative"]["admin_level"="2"]["name"="Việt Nam"](area.vn)($bbox);
        relation["boundary"="administrative"]["admin_level"="4"](area.vn)($bbox);
      );
      out tags;
    """;

    List<String> servers = [
      'https://lz4.overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://api.openstreetmap.fr/oapi/interpreter',
      'https://overpass-api.de/api/interpreter',
      'https://overpass.openstreetmap.ru/api/interpreter',
      'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    ];

    Set<String> provinceNames = {};
    bool hasVietnamBorder = false;
    
    try {
      final response = await _raceToFindServer(servers, query);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data['elements'] != null) {
          for (var element in data['elements']) {
            if (element['tags'] != null && element['tags']['name'] != null) {
              String name = element['tags']['name'];
              String adminLevel = element['tags']['admin_level'] ?? "";
              
              if (adminLevel == "2") {
                String lowerName = name.toLowerCase();
                if (lowerName.contains('việt nam') || lowerName.contains('vietnam')) {
                  hasVietnamBorder = true;
                }
                continue;
              }
              
              if (_isVietnameseProvince(name)) {
                provinceNames.add(name);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Lỗi Overpass query: $e");
    }

    if (provinceNames.isEmpty && !hasVietnamBorder) {
      debugPrint("❌ Không tìm thấy tỉnh/biên giới VN nào trong KMZ bounds");
      return;
    }

    List<RoadData> allBoundaries = [];
    
    if (hasVietnamBorder) {
      await _fetchProvinceBoundaryNominatim("Việt Nam", bounds, allBoundaries);
    }
    
    List<String> provinceList = provinceNames.toList();
    for (int i = 0; i < provinceList.length; i += 5) {
      if (!mounted) return;
      
      int end = (i + 5 > provinceList.length) ? provinceList.length : i + 5;
      List<String> batch = provinceList.sublist(i, end);
      
      await Future.wait(
        batch.map((name) => _fetchProvinceBoundaryNominatim(name, bounds, allBoundaries)),
      );
      
      if (end < provinceList.length) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    if (allBoundaries.isNotEmpty && mounted) {
      await _mergeAndSave(allBoundaries, "Ranh giới từ API");
      
      if (mounted) {
        setState(() {
          _populateLayerGroups();
        });
      }
      
      debugPrint("✅ Đã tải xong ${allBoundaries.length} đoạn ranh giới từ API");
    }
  }

  // Kiểm tra tên tỉnh có phải của VN không
  bool _isVietnameseProvince(String name) {
    // Danh sách các tỉnh VN (để filter chính xác)
    List<String> vnProvinces = [
      'Hà Nội', 'Hồ Chí Minh', 'Đà Nẵng', 'Hải Phòng', 'Cần Thơ',
      'An Giang', 'Bà Rịa', 'Vũng Tàu', 'Bắc Giang', 'Bắc Kạn', 'Bạc Liêu',
      'Bắc Ninh', 'Bến Tre', 'Bình Định', 'Bình Dương', 'Bình Phước',
      'Bình Thuận', 'Cà Mau', 'Cao Bằng', 'Đắk Lắk', 'Đắk Nông',
      'Điện Biên', 'Đồng Nai', 'Đồng Tháp', 'Gia Lai', 'Hà Giang',
      'Hà Nam', 'Hà Tĩnh', 'Hải Dương', 'Hậu Giang', 'Hòa Bình',
      'Hưng Yên', 'Khánh Hòa', 'Kiên Giang', 'Kon Tum', 'Lai Châu',
      'Lâm Đồng', 'Lạng Sơn', 'Lào Cai', 'Long An', 'Nam Định',
      'Nghệ An', 'Ninh Bình', 'Ninh Thuận', 'Phú Thọ', 'Phú Yên',
      'Quảng Bình', 'Quảng Nam', 'Quảng Ngãi', 'Quảng Ninh', 'Quảng Trị',
      'Sóc Trăng', 'Sơn La', 'Tây Ninh', 'Thái Bình', 'Thái Nguyên',
      'Thanh Hóa', 'Thừa Thiên Huế', 'Tiền Giang', 'Trà Vinh', 'Tuyên Quang',
      'Vĩnh Long', 'Vĩnh Phúc', 'Yên Bái',
    ];
    
    // Check exact match hoặc contains
    for (var vn in vnProvinces) {
      if (name.contains(vn) || vn.contains(name)) {
        return true;
      }
    }
    
    // Check có dấu tiếng Việt
    RegExp vnDiacritics = RegExp(r'[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]', caseSensitive: false);
    if (vnDiacritics.hasMatch(name)) {
    // Loại trừ các địa danh nước ngoài
    List<String> foreignKeywords = ['Trung Quốc', 'China', 'Lào', 'Laos', 'Campuchia', 'Cambodia', 'Myanmar', 'Thái Lan', 'ສ', 'ງ', 'ວ'];
    for (var foreign in foreignKeywords) {
      if (name.contains(foreign)) {
        return false;
      }
    }
      return true;
    }
    
    return false;
  }

  // Tải boundary của 1 tỉnh từ Nominatim
  Future<void> _fetchProvinceBoundaryNominatim(
    String provinceName, 
    LatLngBounds clipBounds,
    List<RoadData> outputList,
  ) async {
    try {
      String url = Uri.encodeFull(
        "https://nominatim.openstreetmap.org/search?q=$provinceName, Vietnam&format=json&polygon_geojson=1&limit=1",
      );
      
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'iDMAV_Mobile_App'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data.isEmpty) return;
        
        var place = data[0];
        var geojson = place['geojson'];
        
        if (geojson == null || geojson['coordinates'] == null) return;

        String type = geojson['type'];

        // Xử lý Polygon hoặc MultiPolygon
        if (type == 'Polygon') {
          _parsePolygonToRoadData(
            geojson['coordinates'][0], 
            provinceName, 
            clipBounds, 
            outputList,
          );
        } else if (type == 'MultiPolygon') {
          for (var polygon in geojson['coordinates']) {
            _parsePolygonToRoadData(
              polygon[0], 
              provinceName, 
              clipBounds, 
              outputList,
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Lỗi fetch boundary $provinceName: $e");
    }
  }

  // Parse polygon coordinates thành RoadData
  void _parsePolygonToRoadData(
    List<dynamic> coords,
    String name,
    LatLngBounds clipBounds,
    List<RoadData> outputList,
  ) {
    List<LatLng> points = [];
    for (var coord in coords) {
      points.add(LatLng(coord[1], coord[0])); // [lng, lat] -> LatLng(lat, lng)
    }
    
    if (points.length > 2) {
      // Clip vào bounds
      List<LatLng> clipped = [];
      for (var p in points) {
        if (clipBounds.contains(p)) clipped.add(p);
      }
      
      if (clipped.length > 2) {
        outputList.add(RoadData(
          id: "nominatim_${name}_${Random().nextInt(99999)}",
          name: name,
          ref: "",
          type: 'boundary',
          points: _simplifyPoints(clipped, threshold: 0.002),
          colorValue: Colors.purpleAccent.value,
          width: 4.0,
          isMaritime: false,
        ));
      }
    }
  }

  // --- TÌM RANH GIỚI QUA NOMINATIM (NHANH HƠN) ---

  /// [RACE SEARCH] Tìm kiếm online - race giữa nhiều server
  /// Server nào trả về trước thì dùng kết quả đó
  /// [CẢI TIẾN] Có cache và lịch sử tìm kiếm
  Future<void> _searchOnline() async {
    String rawKeyword = _searchCtrl.text.trim();
    if (rawKeyword.isEmpty) return;

    String cacheKey = rawKeyword.toUpperCase();
    
    // [MỚI] Kiểm tra cache - nếu đã tìm trước đó thì dùng lại
    if (_searchCache.containsKey(cacheKey)) {
      debugPrint('📦 CACHE HIT: "$cacheKey" - Lấy từ cache');
      final Stopwatch cacheStopwatch = Stopwatch()..start();
      
      List<Polyline> cachedLines = _searchCache[cacheKey]!;
      
      // Cắt lại theo bounds hiện tại (có thể bounds đã thay đổi)
      LatLngBounds bounds = _currentBounds ?? _mapController.camera.visibleBounds;
      List<Polyline> clippedLines = _clipPolylinesToBounds(cachedLines, bounds);
      
      setState(() {
        _displayedPolylines = clippedLines;
        _hasRoadSelected = clippedLines.isNotEmpty;
      });
      
      if (clippedLines.isNotEmpty) {
        _fitCameraToPolylines(clippedLines);
        await _blinkPolylines(3);
        _showAddToPanelDialog(cacheKey, clippedLines);
        
        cacheStopwatch.stop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "⚡ Cache: ${clippedLines.length} kết quả (${cacheStopwatch.elapsedMilliseconds}ms)",
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Không có kết quả trong vùng hiện tại")),
        );
      }
      return; // Không cần gọi API
    }
    
    // [MỚI] Thêm vào lịch sử tìm kiếm
    if (!_searchHistory.contains(cacheKey)) {
      _searchHistory.insert(0, cacheKey); // Mới nhất ở đầu
      if (_searchHistory.length > 20) {
        _searchHistory = _searchHistory.sublist(0, 20);
      }
      _saveAllSettings(); // Lưu lịch sử
    }

    // ⏱️ Bắt đầu đo thời gian
    final Stopwatch totalStopwatch = Stopwatch()..start();
    debugPrint('\n🔍 ========== BẮT ĐẦU TÌM KIẾM ONLINE (RACE): "$rawKeyword" ==========');

    LatLngBounds searchBounds =
        _currentBounds ?? _mapController.camera.visibleBounds;
    setState(() {
      _loadingStatus = "Đang tìm kiếm online...";
      _displayedPolylines.clear();
    });

    // [TỐI ƯU] Giảm buffer từ 0.5 xuống 0.2 để query nhanh hơn
    double buffer = 0.2;
    double south = searchBounds.south - buffer;
    double north = searchBounds.north + buffer;
    double west = searchBounds.west - buffer;
    double east = searchBounds.east + buffer;
    String bbox = '$south,$west,$north,$east';
    
    String flexibleRegex = _createSuperFlexibleRegex(rawKeyword);
    
    // Danh sách 6 server Overpass
    List<String> servers = [
      'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
      'https://lz4.overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://overpass-api.de/api/interpreter',
      'https://overpass.openstreetmap.ru/api/interpreter',
      'https://api.openstreetmap.fr/oapi/interpreter',
    ];
    
    // Query tìm theo REF (chính xác hơn) - [TỐI ƯU] Giảm timeout
    String refQuery = """
      [out:json][timeout:20];
      way["highway"]["highway"!~"_link"]["ref"~"$flexibleRegex",i]($bbox);
      out geom;
    """;
    
    // Query tìm theo NAME
    String nameQuery = """
      [out:json][timeout:20];
      way["highway"]["highway"!~"_link"]["name"~"$flexibleRegex",i]($bbox);
      out geom;
    """;
    
    debugPrint('🚀 Race giữa ${servers.length} server...');

    try {
      final apiStopwatch = Stopwatch()..start();
      
      // Race giữa các server - chạy cả ref và name query song song
      final results = await Future.wait([
        _raceToFindServer(servers, refQuery).catchError((e) {
          debugPrint('⚠️ Ref query lỗi: $e');
          return http.Response('{"elements":[]}', 200);
        }),
        _raceToFindServer(servers, nameQuery).catchError((e) {
          debugPrint('⚠️ Name query lỗi: $e');
          return http.Response('{"elements":[]}', 200);
        }),
      ]);
      
      apiStopwatch.stop();
      debugPrint('⏱️ Thời gian gọi API (race): ${apiStopwatch.elapsedMilliseconds}ms');
      
      // Gộp kết quả từ cả ref và name query
      Set<int> seenIds = {}; // Để loại bỏ trùng lặp
      List<Polyline> foundLines = [];
      int totalElements = 0;
      
      for (var response in results) {
        if (response.statusCode == 200) {
          try {
            final data = jsonDecode(response.body);
            if (data['elements'] != null) {
              for (var element in data['elements']) {
                if (element['type'] == 'way' && element['geometry'] != null) {
                  // Loại bỏ trùng lặp theo ID
                  int wayId = element['id'] ?? 0;
                  if (seenIds.contains(wayId)) continue;
                  seenIds.add(wayId);
                  
                  totalElements++;
                  List<LatLng> pts = [];
                  for (var geom in element['geometry']) {
                    pts.add(LatLng(geom['lat'], geom['lon']));
                  }
                  
                  List<LatLng> simplified = _simplifyForRendering(pts);
                  
                  foundLines.add(
                    Polyline(
                      points: simplified,
                      color: Colors.blueAccent,
                      strokeWidth: 7.0,
                      borderColor: Colors.white,
                      borderStrokeWidth: 2.0,
                      isDotted: false,
                    ),
                  );
                }
              }
            }
          } catch (e) {
            debugPrint('⚠️ Lỗi parse response: $e');
          }
        }
      }
      
      debugPrint('📊 Tổng: $totalElements đường unique');
      
      // Áp dụng logic lọc
      List<Polyline> filteredLines = _filterRelevantSegments(
        foundLines, 
        thresholdRatio: 0.0,
      );

      // Cắt gọn trong khung
      LatLngBounds bounds = _currentBounds ?? _mapController.camera.visibleBounds;
      List<Polyline> clippedLines = _clipPolylinesToBounds(filteredLines, bounds);
      
      // ⏱️ Đo thời gian vẽ
      final drawStopwatch = Stopwatch()..start();
      setState(() {
        _displayedPolylines = clippedLines;
        _hasRoadSelected = clippedLines.isNotEmpty;
      });
      drawStopwatch.stop();
      debugPrint('⏱️ Thời gian xử lý & vẽ: ${drawStopwatch.elapsedMilliseconds}ms');
      
      if (clippedLines.isNotEmpty) {
        // [MỚI] Lưu vào cache (lưu filteredLines để có thể cắt lại theo bounds khác)
        _searchCache[cacheKey] = filteredLines;
        debugPrint('💾 Đã lưu "$cacheKey" vào cache (${filteredLines.length} đường)');
        
        _fitCameraToPolylines(clippedLines);
        
        await _blinkPolylines(3);
        
        String searchedRef = rawKeyword.toUpperCase();
        _showAddToPanelDialog(searchedRef, clippedLines);
        
        // ⏱️ Tổng thời gian (không tính blink)
        totalStopwatch.stop();
        final totalMs = totalStopwatch.elapsedMilliseconds;
        debugPrint('⏱️ TỔNG THỜI GIAN: ${totalMs}ms (${(totalMs/1000).toStringAsFixed(1)}s)');
        debugPrint('🔍 ========== KẾT THÚC TÌM KIẾM ==========\n');
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✅ Tìm thấy ${clippedLines.length} kết quả online (${(totalMs/1000).toStringAsFixed(1)}s)",
            ),
          ),
        );
      } else {
        totalStopwatch.stop();
        debugPrint('⏱️ TỔNG THỜI GIAN (không có kết quả): ${totalStopwatch.elapsedMilliseconds}ms');
        debugPrint('🔍 ========== KẾT THÚC TÌM KIẾM ==========\n');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Không tìm thấy trên các trục đường chính!"),
          ),
        );
      }
    } catch (e) {
      debugPrint("Lỗi tìm kiếm: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Lỗi: $e"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() => _loadingStatus = null);
    }
  }

  /// [MỚI] Hiệu ứng nhấp nháy đường tìm được
  /// Bật 3 lần - Tắt 3 lần rồi sáng hẳn
  Future<void> _blinkPolylines(int times) async {
    if (_displayedPolylines.isEmpty) return;
    
    final List<Polyline> savedLines = List.from(_displayedPolylines);
    
    // Đánh dấu có đường đang được chọn (giữ nút DÒ BIT hiển thị)
    setState(() => _hasRoadSelected = true);
    
    for (int i = 0; i < times; i++) {
      // Bật
      setState(() => _displayedPolylines = savedLines);
      await Future.delayed(const Duration(milliseconds: 300));
      // Tắt
      setState(() => _displayedPolylines = []);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    
    // Sáng hẳn cuối cùng
    setState(() => _displayedPolylines = savedLines);
  }

  /// [MỚI] Tìm kiếm bằng VietMap API
  /// Sử dụng Search API để tìm đường, địa điểm
  Future<void> _searchVietMap() async {
    String rawKeyword = _searchCtrl.text.trim();
    if (rawKeyword.isEmpty) return;

    setState(() {
      _loadingStatus = "Đang tìm kiếm bằng VietMap...";
      _displayedPolylines.clear();
    });

    try {
      final vietmapService = VietMapService();
      
      // Lấy vị trí trung tâm của bounds hiện tại để ưu tiên kết quả gần đó
      LatLng? focusPoint;
      LatLngBounds? searchBounds;
      
      if (_currentBounds != null) {
        focusPoint = _currentBounds!.center;
        searchBounds = _currentBounds;
      } else if (_isMapReady) {
        focusPoint = _mapController.camera.center;
        searchBounds = _mapController.camera.visibleBounds;
      }
      
      // Gọi VietMap Search API
      List<VietMapSearchResult> results = await vietmapService.search(
        rawKeyword,
        location: focusPoint,
        bounds: searchBounds,
        limit: 30, // Tăng limit để có nhiều kết quả hơn
      );
      
      if (results.isEmpty) {
        setState(() => _loadingStatus = null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Không tìm thấy '$rawKeyword' trên VietMap"),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      
      // Chuyển kết quả thành markers và/hoặc polylines
      List<Polyline> foundLines = [];
      List<Marker> foundMarkers = [];
      
      for (var result in results) {
        // Nếu là đường (street/road) - thử lấy routing để vẽ
        if (result.layer == 'street' || result.layer == 'address') {
          // Với street, tạm thời hiển thị như marker
          // (VietMap Search không trả về geometry của đường)
        }
        
        // Tạo marker tại vị trí kết quả
        foundMarkers.add(
          Marker(
            point: result.location,
            width: 150,
            height: 50,
            child: GestureDetector(
              onTap: () {
                // Hiển thị thông tin chi tiết
                _showVietMapResultInfo(result);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: primaryDark.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: Colors.black38, blurRadius: 4),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (result.street != null)
                      Text(
                        result.street!,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      
      // Cập nhật UI
      setState(() {
        _displayedPolylines = foundLines;
        // Thêm markers vào grid markers tạm thời
        _gridMarkers = [..._gridMarkers, ...foundMarkers];
        _loadingStatus = null;
      });
      
      // Bay tới vùng có kết quả
      if (results.isNotEmpty) {
        // Nếu chỉ có 1 kết quả, zoom vào đó
        if (results.length == 1) {
          _mapController.move(results.first.location, 15);
        } else {
          // Nhiều kết quả, fit bounds
          double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
          for (var r in results) {
            if (r.location.latitude < minLat) minLat = r.location.latitude;
            if (r.location.latitude > maxLat) maxLat = r.location.latitude;
            if (r.location.longitude < minLng) minLng = r.location.longitude;
            if (r.location.longitude > maxLng) maxLng = r.location.longitude;
          }
          _mapController.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds(
              LatLng(minLat, minLng),
              LatLng(maxLat, maxLng),
            ),
            padding: const EdgeInsets.all(50),
          ));
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✅ Tìm thấy ${results.length} kết quả từ VietMap"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Lỗi VietMap Search: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Lỗi kết nối VietMap: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingStatus = null);
    }
  }

  /// Hiển thị thông tin chi tiết kết quả VietMap
  void _showVietMapResultInfo(VietMapSearchResult result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Row(
          children: [
            const Icon(Icons.location_on, color: primaryDark),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                result.name,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.label, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            if (result.street != null)
              _buildInfoRow(Icons.streetview, "Đường", result.street!),
            if (result.locality != null)
              _buildInfoRow(Icons.location_city, "Địa phương", result.locality!),
            if (result.region != null)
              _buildInfoRow(Icons.map, "Tỉnh/TP", result.region!),
            _buildInfoRow(
              Icons.gps_fixed, 
              "Tọa độ", 
              "${result.location.latitude.toStringAsFixed(6)}, ${result.location.longitude.toStringAsFixed(6)}",
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Đóng"),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryDark,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.directions, size: 18),
            label: const Text("Chỉ đường"),
            onPressed: () {
              Navigator.pop(ctx);
              _showRoutingDialog(result.location);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Text("$label: ", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// Dialog chỉ đường từ vị trí hiện tại đến điểm đích
  void _showRoutingDialog(LatLng destination) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text("Chỉ đường VietMap"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Chọn điểm xuất phát:"),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.center_focus_strong),
              title: const Text("Tâm bản đồ hiện tại"),
              onTap: () {
                Navigator.pop(ctx);
                _calculateRoute(_mapController.camera.center, destination);
              },
            ),
            if (_currentBounds != null)
              ListTile(
                leading: const Icon(Icons.crop_square),
                title: const Text("Tâm khung KMZ"),
                onTap: () {
                  Navigator.pop(ctx);
                  _calculateRoute(_currentBounds!.center, destination);
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Hủy"),
          ),
        ],
      ),
    );
  }

  /// Tính toán và vẽ tuyến đường bằng VietMap Routing API
  Future<void> _calculateRoute(LatLng origin, LatLng destination) async {
    setState(() => _loadingStatus = "Đang tính tuyến đường...");
    
    try {
      final route = await VietMapService().getRoute(origin, destination);
      
      if (route != null && route.points.isNotEmpty) {
        // Vẽ tuyến đường lên map
        setState(() {
          _displayedPolylines = [
            Polyline(
              points: route.points,
              color: Colors.blue,
              strokeWidth: 6.0,
              borderColor: Colors.white,
              borderStrokeWidth: 2.0,
            ),
          ];
        });
        
        // Fit camera theo tuyến đường
        _fitCameraToPolylines(_displayedPolylines);
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("🛣️ ${route.distanceFormatted} - ${route.timeFormatted}"),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Không tìm được tuyến đường"),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      debugPrint("Lỗi VietMap Routing: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Lỗi tính tuyến đường: $e"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() => _loadingStatus = null);
    }
  }

  /// [MỚI] Xử lý long press trên bản đồ - Reverse Geocoding
  Future<void> _onMapLongPress(LatLng point) async {
    // Hiển thị loading tạm
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text("Đang tìm thông tin tại ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}..."),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final address = await VietMapService().reverseGeocode(point.latitude, point.longitude);
      
      if (address != null && mounted) {
        _showReverseGeocodeResult(address, point);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Không tìm thấy thông tin tại vị trí này"),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      debugPrint("Lỗi reverse geocode: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Lỗi: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Hiển thị kết quả reverse geocoding
  void _showReverseGeocodeResult(VietMapAddress address, LatLng point) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.place, color: Colors.green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    address.streetName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (address.distance != null)
                    Text(
                      "Cách ${address.distance!.toInt()}m",
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                address.label,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            if (address.street != null)
              _buildInfoRow(Icons.edit_road, "Đường", address.street!),
            if (address.houseNumber != null)
              _buildInfoRow(Icons.home, "Số nhà", address.houseNumber!),
            if (address.locality != null)
              _buildInfoRow(Icons.location_city, "Phường/Xã", address.locality!),
            if (address.district != null)
              _buildInfoRow(Icons.domain, "Quận/Huyện", address.district!),
            if (address.region != null)
              _buildInfoRow(Icons.map, "Tỉnh/TP", address.region!),
            const Divider(),
            _buildInfoRow(
              Icons.gps_fixed, 
              "Tọa độ", 
              "${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}",
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Đóng"),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.directions, size: 18),
            label: const Text("Chỉ đường đến đây"),
            onPressed: () {
              Navigator.pop(ctx);
              _showRoutingDialog(point);
            },
          ),
        ],
      ),
    );
  }

  void _searchOffline() async {
    String rawKeyword = _searchCtrl.text.trim();
    if (rawKeyword.isEmpty) {
      setState(() => _displayedPolylines = []);
      return;
    }

    List<Polyline> lines = [];
    
  // Mode 0: Đường đi - Ưu tiên tìm trong assets roads trước
  List<Polyline> assetLines = await _searchRoadFromAssets(rawKeyword);
  if (assetLines.isNotEmpty) {
      lines.addAll(assetLines);
      debugPrint("✅ Tìm thấy ${assetLines.length} đoạn từ assets roads");
  }
    
    // Tìm trong cached roads (dữ liệu đã download trước đó)
  for (var road in _cachedRoads) {
    if (road.type == 'boundary') continue;

    bool matchName = RoadAssetService().isSmartMatch(road.name, rawKeyword);
    bool matchRef = RoadAssetService().isSmartMatch(road.ref, rawKeyword);

    if (matchName || matchRef) {
      List<LatLng> renderPoints = _simplifyForRendering(road.points);
      double renderWidth = lines.length > 20 ? road.width * 0.7 : road.width;
      lines.add(
        Polyline(
          points: renderPoints,
          color: (_currentMapType == MapType.satellite
                    ? Color(road.colorValue)
                    : Color(road.colorValue).withValues(alpha: 0.8)),
          strokeWidth: renderWidth,
          borderStrokeWidth: 0,
          strokeCap: StrokeCap.round,
          strokeJoin: StrokeJoin.round,
          isDotted: false,
        ),
      );
    }
  }

    // Áp dụng lọc nhiễu và cắt gọn giống Online
    // 1. Lọc nhiễu (Connected Components)
    List<Polyline> filteredLines = _filterRelevantSegments(
      lines,
      thresholdRatio: 0.0, // Giữ tất cả, không xóa đoạn ngắn
      // connectionDist: 500.0, // Coi các đoạn cách nhau 2km là cùng 1 nhóm
    );

    // 2. Cắt gọn theo khung nhìn hiện tại
    LatLngBounds bounds = _currentBounds ?? _mapController.camera.visibleBounds;
    List<Polyline> clippedLines = _clipPolylinesToBounds(filteredLines, bounds);

    setState(() => _displayedPolylines = clippedLines);
    if (clippedLines.isNotEmpty) {
      _fitCameraToPolylines(clippedLines);
      
      // [MỚI] Nhấp nháy 3 lần rồi sáng hẳn
      await _blinkPolylines(3);
      
      // Hiển dialog hỏi người dùng có muốn thêm vào Panel không
      String searchedRef = rawKeyword.toUpperCase();
      _showAddToPanelDialog(searchedRef, clippedLines);
    }
    else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Không tìm thấy trong Cache (Nhập chính xác tên/mã)"),
        ),
      );
    }
  }

  /// [MỚI] Tìm đường từ assets (offline data)
  Future<List<Polyline>> _searchRoadFromAssets(String keyword) async {
    try {
      final roadService = RoadAssetService();
      bool loaded = await roadService.loadFromAssets();
      
      if (!loaded) {
        debugPrint("⚠️ Chưa có dữ liệu roads trong assets");
        return [];
      }
      
      // Tìm theo ref hoặc tên
      List<VnRoadData> matches = roadService.findByName(keyword);
      
      // Nếu không tìm thấy theo tên, thử tìm theo ref
      if (matches.isEmpty) {
        VnRoadData? exactMatch = roadService.findByRef(keyword);
        if (exactMatch != null) {
          matches = [exactMatch];
        }
      }
      
      if (matches.isEmpty) return [];
      
      // Chuyển thành Polylines
      List<Polyline> result = [];
      for (var road in matches) {
        result.addAll(roadService.toPolylines(road));
      }
      
      debugPrint("📍 Tìm thấy ${matches.length} tuyến, ${result.length} đoạn từ assets");
      return result;
    } catch (e) {
      debugPrint("Lỗi tìm kiếm từ assets: $e");
      return [];
    }
  }

  // Dialog hỏi thêm đường vào Panel
  void _showAddToPanelDialog(String roadName, List<Polyline> polylines) {
    // Check đã có trong panel chưa
    if (_manualAddedRoads.containsKey(roadName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("'$roadName' đã có trong danh sách riêng rồi"),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }

    // [FIX] Check đã có trong dữ liệu offline chính chưa (Cached Roads)
    bool alreadyInCache = _cachedRoads.any((r) => 
        RoadAssetService().isSmartMatch(r.ref, roadName) || 
        RoadAssetService().isSmartMatch(r.name, roadName) || 
        r.ref.toUpperCase() == roadName.toUpperCase()
    );

    if (alreadyInCache) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("'$roadName' đã có sẵn trong Dữ liệu Offline!"),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    
    showDialog(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) => Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("$roadName (${polylines.length} đoạn)", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(width: 12),
                  TextButton(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("Bỏ", style: TextStyle(fontSize: 12)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryDark,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _manualAddedRoads[roadName] = List.from(polylines);
                      _populateLayerGroups();
                      _selectedLayerIds.add('road_$roadName');
                      _saveManualRoadsToFile();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("✅ '$roadName' đã thêm"),
                          backgroundColor: Colors.green,
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    child: const Text("Thêm", style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Dialog xác nhận xóa đường khỏi Panel
  void _showDeleteRoadDialog(String roadName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text("Xóa dữ liệu?"),
        content: Text(
          "Bạn có muốn xóa '$roadName' khỏi danh sách không?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Hủy"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              // [SỬA] Gọi hàm xóa chung để cập nhật cả polylines hiển thị
              _deleteRoadFromPanel(roadName);
            },
            child: const Text("Xóa"),
          ),
        ],
      ),
    );
  }
  
  // --- [TÍNH NĂNG MỚI] LỌC NHIỄU (CONNECTED COMPONENTS) ---
  List<Polyline> _filterRelevantSegments(
    List<Polyline> input, {
    double thresholdRatio = 0.2,
    double connectionDist = 50.0,
  }) {
    if (input.isEmpty) return [];
    
    // [TỐI ƯU] Early exit: Nếu threshold = 0 -> Giữ tất cả, không cần chạy O(n²)
    if (thresholdRatio <= 0.0) return input;
    // 1. Hàm tính độ dài
    double getLength(Polyline p) {
      double len = 0;
      const Distance distance = Distance();
      for (int i = 0; i < p.points.length - 1; i++) {
        len += distance.as(LengthUnit.Meter, p.points[i], p.points[i + 1]);
      }
      return len;
    }

    // 2. Xây dựng đồ thị kết nối
    double thresholdMeters = connectionDist;
    const Distance distance = Distance();
    
    List<List<int>> adjacency = List.generate(input.length, (_) => []);
    
    for (int i = 0; i < input.length; i++) {
      for (int j = i + 1; j < input.length; j++) {
        LatLng s1 = input[i].points.first;
        LatLng e1 = input[i].points.last;
        LatLng s2 = input[j].points.first;
        LatLng e2 = input[j].points.last;
        
        if (distance.as(LengthUnit.Meter, s1, s2) < thresholdMeters ||
            distance.as(LengthUnit.Meter, s1, e2) < thresholdMeters ||
            distance.as(LengthUnit.Meter, e1, s2) < thresholdMeters ||
            distance.as(LengthUnit.Meter, e1, e2) < thresholdMeters) {
          adjacency[i].add(j);
          adjacency[j].add(i);
        }
      }
    }

    // 3. Tìm các thành phần liên thông (Connected Components)
    List<List<int>> components = [];
    Set<int> visited = {};
    
    for (int i = 0; i < input.length; i++) {
      if (!visited.contains(i)) {
        List<int> component = [];
        List<int> queue = [i];
        visited.add(i);
        while (queue.isNotEmpty) {
          int u = queue.removeAt(0);
          component.add(u);
          for (int v in adjacency[u]) {
            if (!visited.contains(v)) {
              visited.add(v);
              queue.add(v);
            }
          }
        }
        components.add(component);
      }
    }

    // 4. Tính tổng độ dài cho từng nhóm
    List<Map<String, dynamic>> scoredComponents = [];
    for (var comp in components) {
      double totalLen = 0;
      for (int idx in comp) {
        totalLen += getLength(input[idx]);
      }
      scoredComponents.add({
        'indices': comp,
        'length': totalLen,
      });
    }

    // 5. Sắp xếp giảm dần theo độ dài
    scoredComponents.sort((a, b) => (b['length'] as double).compareTo(a['length'] as double));

    if (scoredComponents.isEmpty) return input;

    // 6. Lọc dựa trên threshold ratio
    // Nếu threshold = 0.0 -> Giữ tất cả
    if (thresholdRatio <= 0.0) return input;

    double maxLength = scoredComponents[0]['length'];
    List<Polyline> result = [];
    
    for (var comp in scoredComponents) {
      if ((comp['length'] as double) > maxLength * thresholdRatio) {
        for (int idx in comp['indices']) {
          result.add(input[idx]);
        }
      }
    }

    return result;
  }

  void _executeSearch() {
    // Thực thi tìm kiếm theo nguồn đã chọn
    switch (_searchSource) {
      case SearchSource.offline:
        if (_cachedRoads.isEmpty && !RoadAssetService().isLoaded) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Kho dữ liệu trống. Hãy tải trước!")),
          );
        } else {
          _searchOffline();
        }
        break;
      case SearchSource.osm:
        _searchOnline(); // Overpass API (OSM)
        break;
    }
  }

  // --- [TÍNH NĂNG MỚI] CẮT LINE THEO KHUNG (CLIPPING) ---
  List<Polyline> _clipPolylinesToBounds(List<Polyline> lines, LatLngBounds bounds) {
    List<Polyline> result = [];
    
    for (var line in lines) {
      List<LatLng> points = line.points;
      if (points.isEmpty) continue;

      List<LatLng> currentSegment = [];
      
      for (int i = 0; i < points.length - 1; i++) {
        LatLng p1 = points[i];
        LatLng p2 = points[i+1];
        
        bool p1In = bounds.contains(p1);
        bool p2In = bounds.contains(p2);

        if (p1In && p2In) {
          // Cả 2 trong -> Thêm p2 (p1 đã thêm ở vòng trước hoặc là điểm đầu)
          if (currentSegment.isEmpty) currentSegment.add(p1);
          currentSegment.add(p2);
        } else if (p1In && !p2In) {
          // Đi từ trong ra ngoài -> Tìm giao điểm
          if (currentSegment.isEmpty) currentSegment.add(p1);
          LatLng? intersection = _getIntersection(p1, p2, bounds);
          if (intersection != null) currentSegment.add(intersection);
          
          // Kết thúc segment hiện tại
          if (currentSegment.length > 1) {
            result.add(_clonePolyline(line, currentSegment));
          }
          currentSegment = [];
        } else if (!p1In && p2In) {
          // Đi từ ngoài vào trong -> Tìm giao điểm -> Bắt đầu segment mới
          LatLng? intersection = _getIntersection(p1, p2, bounds);
          if (intersection != null) {
            currentSegment.add(intersection);
            currentSegment.add(p2);
          }
        } else {
          // Cả 2 ngoài -> Có thể cắt ngang qua khung?
          // Đơn giản hóa: Bỏ qua (hoặc check kỹ hơn nếu cần chính xác tuyệt đối)
          // Với map tiles nhỏ thì ít khi xảy ra trường hợp cắt ngang mà ko có điểm nào bên trong
        }
      }
      
      if (currentSegment.length > 1) {
        result.add(_clonePolyline(line, currentSegment));
      }
    }
    return result;
  }

  Polyline _clonePolyline(Polyline original, List<LatLng> newPoints) {
    return Polyline(
      points: newPoints,
      color: original.color,
      strokeWidth: original.strokeWidth,
      borderColor: original.borderColor,
      borderStrokeWidth: original.borderStrokeWidth,
      isDotted: original.isDotted,
      strokeCap: original.strokeCap,
      strokeJoin: original.strokeJoin,
    );
  }

  LatLng? _getIntersection(LatLng p1, LatLng p2, LatLngBounds bounds) {
    // Cohen-Sutherland like clipping logic or simple line intersection
    // Cạnh của bounds: North, South, East, West
    double minLat = bounds.south;
    double maxLat = bounds.north;
    double minLng = bounds.west;
    double maxLng = bounds.east;

    // Helper check
    bool isInside(LatLng p) => 
      p.latitude >= minLat && p.latitude <= maxLat && 
      p.longitude >= minLng && p.longitude <= maxLng;

    // Tìm giao điểm với 4 cạnh
    List<LatLng> intersections = [];
    
    // Hàm tìm giao điểm đoạn thẳng (p1, p2) với đường thẳng (a, b)
    // Ở đây đường thẳng là các cạnh ngang/dọc
    
    // Cắt với North (Lat = maxLat)
    if ((p1.latitude - maxLat) * (p2.latitude - maxLat) < 0) {
      double t = (maxLat - p1.latitude) / (p2.latitude - p1.latitude);
      double lng = p1.longitude + t * (p2.longitude - p1.longitude);
      if (lng >= minLng && lng <= maxLng) intersections.add(LatLng(maxLat, lng));
    }
    // Cắt với South (Lat = minLat)
    if ((p1.latitude - minLat) * (p2.latitude - minLat) < 0) {
      double t = (minLat - p1.latitude) / (p2.latitude - p1.latitude);
      double lng = p1.longitude + t * (p2.longitude - p1.longitude);
      if (lng >= minLng && lng <= maxLng) intersections.add(LatLng(minLat, lng));
    }
    // Cắt với East (Lng = maxLng)
    if ((p1.longitude - maxLng) * (p2.longitude - maxLng) < 0) {
      double t = (maxLng - p1.longitude) / (p2.longitude - p1.longitude);
      double lat = p1.latitude + t * (p2.latitude - p1.latitude);
      if (lat >= minLat && lat <= maxLat) intersections.add(LatLng(lat, maxLng));
    }
    // Cắt với West (Lng = minLng)
    if ((p1.longitude - minLng) * (p2.longitude - minLng) < 0) {
      double t = (minLng - p1.longitude) / (p2.longitude - p1.longitude);
      double lat = p1.latitude + t * (p2.latitude - p1.latitude);
      if (lat >= minLat && lat <= maxLat) intersections.add(LatLng(lat, minLng));
    }

    // Chọn điểm gần p1 nhất (điểm cắt đầu tiên gặp phải)
    if (intersections.isEmpty) return null;
    
    intersections.sort((a, b) {
      double d1 = (a.latitude - p1.latitude)*(a.latitude - p1.latitude) + (a.longitude - p1.longitude)*(a.longitude - p1.longitude);
      double d2 = (b.latitude - p1.latitude)*(b.latitude - p1.latitude) + (b.longitude - p1.longitude)*(b.longitude - p1.longitude);
      return d1.compareTo(d2);
    });
    
    return intersections.first;
  }

  // (Đã xóa _showDownloadOptionsDialog - không còn dùng)

  Future<void> _resetAllIds() async {
    bool confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Xác nhận"),
        content: const Text("Bạn có chắc chắn muốn xóa tất cả ID phần cứng đã nhập?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Hủy"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Xóa", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    ) ?? false;

    if (confirm) {
      setState(() {
        _tileControlIds.clear();
        if (_currentBounds != null) _generateGridOnMap(_currentBounds!);
      });
      await _saveAllSettings();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Đã xóa tất cả ID phần cứng!")),
      );
    }
  }

  void _showConfigDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              title: const Text("Cấu hình Khung"),
              content: SizedBox(
                width: MediaQuery.of(context).size.width,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(child: _buildInput("Chiều Dài Sa Bàn (cm)", _heightCtrl)),
                          const SizedBox(width: 10),
                          Expanded(child: _buildInput("Chiều Rộng Sa Bàn (cm)", _widthCtrl)),
                        ],
                      ),
                      const SizedBox(height: 15),
                      DropdownButtonFormField<int>(
                        value: _selectedTileSize,
                        decoration: const InputDecoration(
                          labelText: "Kích thước Tấm",
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 50, child: Text("50 cm x 50 cm")),
                          DropdownMenuItem(
                            value: 100,
                            child: Text("100 cm x 100 cm"),
                          ),
                        ],
                        onChanged: (val) => _selectedTileSize = val!,
                      ),
                      const SizedBox(height: 15),
                      SwitchListTile(
                        title: const Text("Hiển thị lưới"),
                        value: _showGrid,
                        activeColor: primaryDark,
                        onChanged: (val) {
                          setStateDialog(() => _showGrid = val);
                          setState(() => _showGrid = val);
                        },
                      ),
                      const SizedBox(height: 15),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.delete_forever, color: Colors.white),
                          label: const Text("Xóa tất cả ID"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            await _resetAllIds();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Hủy"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryDark,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    _confirmAndDrawGrid();
                    Navigator.pop(ctx);
                  },
                  child: const Text("Cập nhật"),
                ),
              ],
            );
          },
        );
      },
    );
  }


  void _showSearchDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 10), // Cho to ra
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            title: const Text("Tìm kiếm & Dữ liệu"),
            content: SizedBox(
               // Chiều rộng max thiết bị
              width: MediaQuery.of(context).size.width,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Nguồn:",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        ToggleButtons(
                          isSelected: [
                            _searchSource == SearchSource.offline,
                            _searchSource == SearchSource.osm,
                          ],
                          borderRadius: BorderRadius.circular(8),
                          selectedColor: Colors.white,
                          fillColor: _searchSource == SearchSource.osm 
                              ? Colors.green 
                              : primaryDark,
                          constraints: const BoxConstraints(
                            minWidth: 65,
                            minHeight: 32,
                          ),
                          onPressed: (index) => setStateDialog(() {
                            _searchSource = SearchSource.values[index];
                          }),
                          children: const [
                            Text("Offline", style: TextStyle(fontSize: 11)),
                            Text("OSM", style: TextStyle(fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    width: 0,
                    height: 0,
                  ),

                  if (_searchSource == SearchSource.offline) ...[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _cachedRoads.isEmpty
                                        ? Icons.warning
                                        : Icons.folder_open,
                                    size: 16,
                                    color: _cachedRoads.isEmpty
                                        ? Colors.red
                                        : Colors.blue,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _cachedRoads.isEmpty
                                        ? "Trống"
                                        : "${_cachedRoads.length} mục",
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              if (_cachedRoads.isNotEmpty)
                                InkWell(
                                  onTap: () async {
                                    bool confirm =
                                        await showDialog(
                                          context: context,
                                          builder: (c) => AlertDialog(
                                            title: const Text("Xác nhận"),
                                            content: const Text(
                                              "Xóa toàn bộ dữ liệu offline?",
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(c, false),
                                                child: const Text("Hủy"),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(c, true),
                                                child: const Text(
                                                  "Xóa",
                                                  style: TextStyle(
                                                    color: Colors.red,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ) ??
                                        false;
                                    if (confirm) {
                                      await _clearAllData();
                                      setStateDialog(() {});
                                    }
                                  },
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 15),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return Autocomplete<String>(
                        optionsBuilder: (TextEditingValue textEditingValue) async {
                          // [MỚI] Gợi ý từ lịch sử tìm kiếm + cache khi online
                          if (_searchSource == SearchSource.osm) {
                            String query = textEditingValue.text.toUpperCase().trim();
                            
                            // Khi ô trống, hiển thị lịch sử tìm kiếm
                            if (query.isEmpty) {
                              // Hiển thị cache trước (có ⚡), sau đó lịch sử
                              List<String> suggestions = [];
                              for (var key in _searchCache.keys.take(5)) {
                                suggestions.add('⚡ $key'); // Cache
                              }
                              for (var item in _searchHistory.take(10)) {
                                if (!_searchCache.containsKey(item)) {
                                  suggestions.add('🕒 $item'); // Lịch sử
                                }
                              }
                              return suggestions;
                            }
                            
                            // Khi có text, lọc theo query
                            List<String> suggestions = [];
                            // Cache phù hợp
                            for (var key in _searchCache.keys) {
                              if (key.contains(query)) {
                                suggestions.add('⚡ $key');
                              }
                            }
                            // Lịch sử phù hợp
                            for (var item in _searchHistory) {
                              if (item.contains(query) && !_searchCache.containsKey(item)) {
                                suggestions.add('🕒 $item');
                              }
                            }
                            return suggestions.take(10);
                          }
                          
                          // Chế độ offline - gợi ý từ assets
                          if (textEditingValue.text.isEmpty) {
                            return const Iterable<String>.empty();
                          }
                          
                          if (_searchSource == SearchSource.offline) {
                            if (!RoadAssetService().isLoaded) {
                               await RoadAssetService().loadFromAssets();
                            }
                            return RoadAssetService().getSuggestions(textEditingValue.text);
                          }
                          return const Iterable<String>.empty();
                        },
                        onSelected: (String selection) {
                          // [MỚI] Bỏ prefix emoji (⚡ hoặc 🕒) nếu có
                          String cleanSelection = selection
                              .replaceFirst('⚡ ', '')
                              .replaceFirst('🕒 ', '');
                          _searchCtrl.text = cleanSelection;
                        },
                        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                          // Sync giá trị từ _searchCtrl vào controller của Autocomplete khi init
                          if (controller.text.isEmpty && _searchCtrl.text.isNotEmpty) {
                            controller.text = _searchCtrl.text;
                          }

                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              hintText: "Nhập tên đường (VD: QL1, CT.01)...",
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              prefixIcon: const Icon(Icons.search),
                              filled: true,
                              fillColor: Colors.white,
                              suffixIcon: controller.text.isNotEmpty 
                                ? IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      controller.clear();
                                      _searchCtrl.clear();
                                    },
                                  )
                                : null,
                            ),
                            onChanged: (val) {
                               _searchCtrl.text = val;
                            },
                            onSubmitted: (_) {
                              onFieldSubmitted();
                              Navigator.pop(ctx); // Đóng dialog
                              _executeSearch();   // Thực hiện tìm kiếm
                            },
                          );
                        },
                        optionsViewBuilder: (context, onSelected, options) {
                          return Align(
                            alignment: Alignment.topLeft,
                            child: Material(
                              elevation: 4,
                              borderRadius: BorderRadius.circular(8),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: 250, 
                                  maxWidth: constraints.maxWidth,
                                ),
                                child: ListView.builder(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: options.length,
                                  itemBuilder: (context, index) {
                                    final option = options.elementAt(index);
                                    return ListTile(
                                      leading: const Icon(Icons.history, size: 20, color: Colors.grey),
                                      title: Text(option, style: const TextStyle(fontSize: 14)),
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      onTap: () => onSelected(option),
                                    );
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _executeSearch();
                      },
                      child: const Text("Tìm & Vẽ"),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [],
          );
        },
      ),
    );
  }



  void _confirmAndDrawGrid() {
    double? w = double.tryParse(_widthCtrl.text);
    double? h = double.tryParse(_heightCtrl.text);
    if (w != null && h != null && w > 0 && h > 0) {
      setState(() {
        _renderWidth = w;
        _renderHeight = h;
      });
      if (_currentBounds != null) _generateGridOnMap(_currentBounds!);
      _saveAllSettings();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Đã cập nhật: ${cols}x$rows")));
    }
  }

  // --- [TÍNH NĂNG MỚI] GÁN ID TẤM ---
  void _onTileTapped(String tileLabel) {
    TextEditingController idCtrl = TextEditingController(
      text: _tileControlIds[tileLabel] ?? "",
    );
    
    showDialog(
      context: context,
      builder: (ctx) {
        String? localError; // Biến local để hiện lỗi trong Dialog
        
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              title: Row(
                children: [
                  const Icon(Icons.grid_view, color: primaryDark),
                  const SizedBox(width: 8),
                  Text("Cấu hình Tấm $tileLabel"),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Nhập ID Điều khiển (Ví dụ: 26, 0A):",
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: idCtrl,
                    autofocus: true,
                    onChanged: (_) {
                      // Xóa lỗi khi người dùng gõ lại
                      if (localError != null) setStateDialog(() => localError = null);
                    },
                    decoration: InputDecoration(
                      hintText: "ID phần cứng...",
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: localError, // Hiển thị lỗi ngay tại đây
                      errorStyle: const TextStyle(
                        color: Colors.redAccent, 
                        fontWeight: FontWeight.bold
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Hủy"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () {
                    String newId = idCtrl.text.trim().toUpperCase();
                    
                    // Validate duplicate ID
                    if (newId.isNotEmpty) {
                      String? existingTile;
                      _tileControlIds.forEach((key, value) {
                        if (value == newId && key != tileLabel) {
                          existingTile = key;
                        }
                      });

                      if (existingTile != null) {
                        // Cập nhật lỗi để hiện lên TextField
                        setStateDialog(() {
                          localError = "ID này đang ở ô $existingTile!";
                        });
                        return; // Stop saving
                      }
                    }

                    // Nếu không lỗi -> Lưu và đóng
                    setState(() {
                      if (newId.isEmpty)
                        _tileControlIds.remove(tileLabel);
                      else
                        _tileControlIds[tileLabel] = newId;
                      if (_currentBounds != null) _generateGridOnMap(_currentBounds!);
                    });
                    Navigator.pop(ctx);
                    _saveAllSettings();
                  },
                  child: const Text("Lưu ID", style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- [TÍNH NĂNG MỚI] SINH LƯỚI CÓ HIỂN THỊ ID ---
  void _generateGridOnMap(LatLngBounds bounds) {
    List<Polygon> newPolygons = [];
    List<Marker> newMarkers = [];
    double totalLat = bounds.north - bounds.south;
    double totalLng = bounds.east - bounds.west;
    double cellHeightLat = totalLat / rows;
    double cellWidthLng = totalLng / cols;
    Color gridColor = (_currentMapType == MapType.satellite) ? Colors.yellowAccent : Colors.red;
    Color textColor = (_currentMapType == MapType.satellite) ? Colors.black : Colors.red;

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        double cellNorth = bounds.north - (r * cellHeightLat);
        double cellSouth = bounds.north - ((r + 1) * cellHeightLat);
        double cellWest = bounds.west + (c * cellWidthLng);
        double cellEast = bounds.west + ((c + 1) * cellWidthLng);

        // Label: A1, A2...
        String tileLabel = "${_getRowLetter(r)}${c + 1}";
        // ID: 26...
        String? assignedId = _tileControlIds[tileLabel];

        newPolygons.add(
          Polygon(
            points: [
              LatLng(cellNorth, cellWest),
              LatLng(cellNorth, cellEast),
              LatLng(cellSouth, cellEast),
              LatLng(cellSouth, cellWest),
            ],
            // Tô màu xanh nếu đã gán ID
            color: assignedId != null
                ? Colors.green.withValues(alpha: 0.15)
                : Colors.transparent,
            borderColor: gridColor.withValues(alpha: 0.7),
            borderStrokeWidth: 1.5,
            isFilled: true,
          ),
        );

        newMarkers.add(
          Marker(
            point: LatLng(
              (cellNorth + cellSouth) / 2,
              (cellWest + cellEast) / 2,
            ),
            width: 50,
            height: 35,
            // Cho phép chạm để gán ID
            child: GestureDetector(
              onTap: () => _onTileTapped(tileLabel),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: assignedId != null
                    ? BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: Colors.green,
                          width: 2.0,
                        ),
                      )
                    : null, // [TỐI ƯU] Bỏ khung hình chữ nhật nếu chưa gán ID
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        tileLabel,
                        style: TextStyle(
                          fontWeight: FontWeight.w900, // [TỐI ƯU] In đậm hơn
                          fontSize: 12, // Tăng size chút cho dễ nhìn
                          color: textColor,
                          shadows: [
                            // Thêm viền trắng cho chữ để dễ đọc trên nền map
                            Shadow(
                              offset: const Offset(-1.0, -1.0),
                              color: Colors.white,
                            ),
                            Shadow(
                              offset: const Offset(1.0, -1.0),
                              color: Colors.white,
                            ),
                            Shadow(
                              offset: const Offset(1.0, 1.0),
                              color: Colors.white,
                            ),
                            Shadow(
                              offset: const Offset(-1.0, 1.0),
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ),
                      // Hiển thị ID nếu có
                      if (assignedId != null)
                        Text(
                          assignedId,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            color: Colors.green,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    setState(() {
      _currentBounds = bounds;
      _gridPolygons = newPolygons;
      _gridMarkers = newMarkers;
    });
  }

  // --- [TÍNH NĂNG MỚI] CHUYỂN DỮ LIỆU SANG SCANNER ---
  void _transferToScanner() {
    // Validate: Phải có ít nhất 1 ô đã được gán ID
    if (_tileControlIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Chưa có ô nào được gán ID! Vui lòng cấu hình trước.",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_displayedPolylines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Chưa có đường nào được vẽ!")),
      );
      return;
    }
    if (_currentBounds == null) return;

    Set<String> intersectedIds = {};

    double totalLat = _currentBounds!.north - _currentBounds!.south;
    double totalLng = _currentBounds!.east - _currentBounds!.west;
    double cellHeightLat = totalLat / rows;
    double cellWidthLng = totalLng / cols;

    // Quét giao thoa: Đường đi qua ô nào -> Lấy ID ô đó
    for (var polyline in _displayedPolylines) {
      for (var point in polyline.points) {
        if (_currentBounds!.contains(point)) {
          double relativeLat = _currentBounds!.north - point.latitude;
          double relativeLng = point.longitude - _currentBounds!.west;
          int r = (relativeLat / cellHeightLat).floor();
          int c = (relativeLng / cellWidthLng).floor();

          if (r >= 0 && r < rows && c >= 0 && c < cols) {
            String tileLabel = "${_getRowLetter(r)}${c + 1}";
            String? controlId = _tileControlIds[tileLabel];
            if (controlId != null && controlId.isNotEmpty) {
              intersectedIds.add(controlId);
            }
          }
        }
      }
    }

    if (intersectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Đường này không đi qua Tấm nào đã gán ID!"),
        ),
      );
      return;
    }

    // Sắp xếp ID
    List<String> sortedIds = intersectedIds.toList();
    sortedIds.sort((a, b) {
      try {
        return int.parse(a, radix: 16).compareTo(int.parse(b, radix: 16));
      } catch (e) {
        return a.compareTo(b);
      }
    });

    // Ưu tiên: lastSelectedLayerName > _searchCtrl.text > "Tuyến đường"
    String roadName = lastSelectedLayerName ?? 
        (_searchCtrl.text.isEmpty ? "Tuyến đường" : _searchCtrl.text);

    // Chuyển sang tab Scanner với dữ liệu
    final mainNavState = context.findAncestorStateOfType<MainNavigationState>();
    if (mainNavState != null) {
      mainNavState.navigateToScanner(
        name: roadName, 
        limitList: sortedIds.join(", "),
      );
    }
  }

  Future<void> _pickAndFitKmz() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['kmz', 'kml'],
      );
      if (result != null) {
        File file = File(result.files.single.path!);
        String extension = result.files.single.extension ?? "";
        String kmlContent = "";
        if (extension.toLowerCase() == 'kmz') {
          final bytes = file.readAsBytesSync();
          final archive = ZipDecoder().decodeBytes(bytes);
          final kmlFile = archive.findFile('doc.kml');
          if (kmlFile != null) kmlContent = utf8.decode(kmlFile.content);
        } else {
          kmlContent = await file.readAsString();
        }
        if (kmlContent.isNotEmpty) _processKmlData(kmlContent);
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Lỗi: $e")));
    }
  }

  // [MỚI] Xóa khung KMZ VÀ tất cả dữ liệu
  Future<void> _clearKmz() async {
    setState(() {
      // Xóa KMZ và lưới
      _kmzPolylines.clear();
      _gridPolygons.clear();
      _currentBounds = null;
      _gridMarkers.clear();
      _tileControlIds.clear();
      
      // Xóa tất cả dữ liệu trong Panel
      _cachedRoads.clear();
      RoadAssetService().clearCache(); // [MỚI] Xóa cache toàn cục của Road Service
      _displayedPolylines.clear();
      _manualAddedRoads.clear();
      _selectedLayerIds.clear();
    });
    
    // Xóa file cache
    try {
      final directory = await getApplicationDocumentsDirectory();
      final roadFile = File('${directory.path}/idmav_roads.json');
      if (await roadFile.exists()) await roadFile.delete();
      final manualFile = File('${directory.path}/idmav_manual_roads.json');
      if (await manualFile.exists()) await manualFile.delete();
    } catch (e) {
      debugPrint("Lỗi xóa file cache: $e");
    }
    
    // Xóa KMZ bounds trong SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('kmz_min_lat');
    await prefs.remove('kmz_max_lat');
    await prefs.remove('kmz_min_lng');
    await prefs.remove('kmz_max_lng');
    await prefs.remove('map_tile_ids');
    
    // Cập nhật Layer Panel
    _populateLayerGroups();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("❌ Đã xóa KMZ và toàn bộ dữ liệu!")),
    );
  }

  /// [MỚI] Hiển thị dialog import/export dữ liệu thống nhất
  void _showImportDialog() {
    showDialog(
      context: context,
      builder: (ctx) => ImportDataDialog(
        currentBounds: _currentBounds,
        onBoundsCreated: (bounds, polylines) {
          setState(() {
            _currentBounds = bounds;
            _kmzPolylines = polylines;
          });
          _generateGridOnMap(bounds);
          
          // [TỐI ƯU] Fit theo chiều ngang (mặc kệ chiều dọc)
          // Tạo bounds giả: Giữ nguyên chiều ngang, chiều dọc ép nhỏ lại
          // để fitCamera luôn tính toán zoom dựa trên chiều ngang.
          double centerLat = bounds.center.latitude;
          LatLngBounds fitWidthBounds = LatLngBounds(
             LatLng(centerLat - 0.001, bounds.west),
             LatLng(centerLat + 0.001, bounds.east),
          );

          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: fitWidthBounds,
              padding: EdgeInsets.zero, 
            ),
          );
          _mapController.rotate(0);
          
          _saveAllSettings();
          _autoDetectProvincesFromKMZ(bounds, skipFitCamera: true);
        },
        onClearBounds: () {
          _clearKmz();
        },
      ),
    );
  }

  Future<void> _processKmlData(String kmlString) async {
    try {
      final document = XmlDocument.parse(kmlString);
      final allCoordinates = document.findAllElements('coordinates');
      List<LatLng> allPoints = [];
      List<Polyline> lines = [];
      for (var node in allCoordinates) {
        String rawText = node.text.trim();
        List<LatLng> segmentPoints = [];
        List<String> pairs = rawText.split(RegExp(r'\s+'));
        for (var pair in pairs) {
          List<String> parts = pair.split(',');
          if (parts.length >= 2) {
            segmentPoints.add(
              LatLng(double.parse(parts[1]), double.parse(parts[0])),
            );
            allPoints.add(
              LatLng(double.parse(parts[1]), double.parse(parts[0])),
            );
          }
        }
        if (segmentPoints.isNotEmpty)
          lines.add(
            Polyline(
              points: segmentPoints,
              color: (_currentMapType == MapType.satellite) ? Colors.cyanAccent : Colors.black,
              strokeWidth: 2,
              isDotted: true,
            ),
          );
      }
      if (allPoints.isEmpty) return;
      double minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
      for (var p in allPoints) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
      LatLngBounds bounds = LatLngBounds(
        LatLng(minLat, minLon),
        LatLng(maxLat, maxLon),
      );
      setState(() {
        _kmzPolylines = lines;
      });
      _generateGridOnMap(bounds);
      
      // [TỐI ƯU] Dùng fitCamera thay vì tính toán thủ công
      // [TỐI ƯU] Fit theo chiều ngang (Force Fit Width)
      double centerLat = bounds.center.latitude;
      LatLngBounds fitWidthBounds = LatLngBounds(
          LatLng(centerLat - 0.001, bounds.west),
          LatLng(centerLat + 0.001, bounds.east),
      );

      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: fitWidthBounds,
          padding: EdgeInsets.zero,
        ),
      );
       
      _mapController.rotate(0); // Hướng Bắc
      
      _saveAllSettings();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Đã tạo lưới theo KMZ!")));
      
      _autoDetectProvincesFromKMZ(bounds, skipFitCamera: true);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Lỗi đọc KMZ")));
    }
  }

  String _getRowLetter(int index) {
    return String.fromCharCode(65 + index);
  }

  @override
  void dispose() {
    _saveAllSettings();
    super.dispose();
  }

  Widget _buildAppBarAction(IconData icon, String label, VoidCallback? onTap) {
    bool isEnabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon, 
              color: isEnabled ? Colors.white : Colors.white38, 
              size: 20,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isEnabled ? Colors.white : Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- [TÍNH NĂNG MỚI] ẨN LABEL KHI ZOOM NHỎ ---
  bool _shouldShowMarkers() {
    if (!_isMapReady ||
        _currentBounds == null ||
        _gridMarkers.isEmpty ||
        cols == 0) {
      return false;
    }
    try {
      double totalLng = _currentBounds!.east - _currentBounds!.west;
      double singleCellLng = totalLng / cols;
      final center = _mapController.camera.center;
      // Tính độ rộng màn hình của 1 ô lưới
      final p1 = _mapController.camera.latLngToScreenPoint(center);
      final p2 = _mapController.camera.latLngToScreenPoint(
        LatLng(center.latitude, center.longitude + singleCellLng),
      );
      double cellScreenWidth = (p2.x - p1.x).abs();
      // Marker width ~50px, nếu ô < 60px thì ẩn để đỡ rối
      return cellScreenWidth > 40;
    } catch (e) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: primaryDark,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          // Nút chọn nền Bản đồ - hiển thị tên nền đang dùng
          PopupMenuButton<MapType>(
            tooltip: "Chọn nền bản đồ",
            padding: EdgeInsets.zero,
            onSelected: (MapType selected) {
              setState(() {
                _currentMapType = selected;
              });
              _saveAllSettings();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.layers, color: Colors.white, size: 20),
                  const SizedBox(height: 2),
                  Text(
                    _getMapTypeName(), // Hiển thị tên nền đang dùng
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            itemBuilder: (context) {
              bool isOnline = OfflineMapService().isOnline;
              return [
                const PopupMenuItem(
                  value: MapType.google,
                  child: Text("Google Maps (Khuyên dùng)"),
                ),
                PopupMenuItem(
                  value: MapType.satellite,
                  enabled: isOnline,
                  child: Text(isOnline ? "Vệ tinh (ArcGIS)" : "Vệ tinh (Cần mạng)"),
                ),
                PopupMenuItem(
                  value: MapType.osm,
                  enabled: isOnline,
                  child: Text(isOnline ? "OpenStreetMap" : "OpenStreetMap (Cần mạng)"),
                ),
                PopupMenuItem(
                  value: MapType.vietmap,
                  // VietMap enabled khi online HOẶC có offline tiles
                  enabled: isOnline || OfflineMapService().hasVietMapOffline,
                  child: Text(isOnline 
                      ? "VietMap" 
                      : (OfflineMapService().hasVietMapOffline 
                          ? "VietMap (Offline)" 
                          : "VietMap (Cần mạng)")),
                ),
              ];
            },
          ),
          _buildAppBarAction(Icons.settings, "Cấu hình sa bàn", _showConfigDialog),
          _buildAppBarAction(
            _cachedRoads.isEmpty ? Icons.cloud_download : Icons.search,
            "Tìm dữ liệu",
            _currentBounds == null 
                ? null 
                : _showSearchDialog,
          ),
          // [MỚI] Nút Import thống nhất (KMZ, tọa độ, hình ảnh, xuất)
          // Disable nếu đã có khung - phải xóa khung trước mới nhập được khung mới
          _buildAppBarAction(
            _currentBounds != null ? Icons.edit_location : Icons.upload_file,
            "Nhập khung",
            _currentBounds == null ? _showImportDialog : null,
          ),
          // Nút xóa khung (chỉ hiện khi có khung)
          if (_currentBounds != null)
            _buildAppBarAction(Icons.delete_outline, "Xóa khung", _clearKmz),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Container(color: Colors.grey[900]),
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _savedCenter,
              initialZoom: _savedZoom,
              // [MỚI] Giới hạn zoom khi offline theo file tiles đã tải (zoom 6-12)
              minZoom: OfflineMapService().isOnline ? 6 : 6.0,
              maxZoom: OfflineMapService().isOnline ? 13 : 12.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapReady: () => setState(() => _isMapReady = true),

              // [TỐI ƯU] Chỉ rebuild khi zoom thay đổi đáng kể (tránh lag)
              onPositionChanged: (position, hasGesture) {
                // Chỉ update UI khi zoom thay đổi >= 0.5 level
                if ((_savedZoom - (position.zoom ?? _savedZoom)).abs() >= 0.5) {
                  _savedZoom = position.zoom ?? _savedZoom;
                  debugPrint('🔍 Zoom: ${_savedZoom.toStringAsFixed(1)}');
                  setState(() {});
                }
              },
              
              // [MỚI] Long press để lấy thông tin địa điểm từ VietMap
              onLongPress: (tapPosition, point) async {
                _onMapLongPress(point);
              },
            ),
            children: [
              // Lớp nền bản đồ (Base Map)
              TileLayer(
                urlTemplate: _getTileUrl(),
                tileBounds: _currentBounds,
                // Sử dụng Hybrid Provider: Online -> API, Offline -> Bundled MBTiles
                // VietMap: Dùng VietMap offline provider nếu có
                tileProvider: _currentMapType == MapType.vietmap
                    ? (OfflineMapService().isOnline
                        ? NetworkTileProvider()
                        : OfflineMapService().vietmapOfflineProvider ?? NetworkTileProvider())
                    : OfflineMapService().getTileProvider(urlTemplate: _getTileUrl()),
              ),
              
              // Lớp nhãn (chỉ cho Vệ tinh để hiện tên đường)
              if (_currentMapType == MapType.satellite)
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                  backgroundColor: Colors.transparent,
                  tileBounds: _currentBounds,
                ),

              PolylineLayer(polylines: _kmzPolylines),
              PolylineLayer(polylines: _displayedPolylines),

              if (_showGrid) ...[
                PolygonLayer(polygons: _gridPolygons),
                // Chỉ hiện marker (A1, A2...) khi ô đủ lớn
                if (_shouldShowMarkers()) MarkerLayer(markers: _gridMarkers),
              ],
            ],
          ),

          if (_loadingStatus != null)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 15),
                    Text(
                      _loadingStatus!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // [MỚI] Layer Tree Panel
          _buildLayerTreePanel(),
          _buildLayerPanelToggle(),

          // [MỚI] Nút chuyển sang Dò Bit - Tách riêng để không bị ảnh hưởng khi đường nháy
          if (_hasRoadSelected)
            Positioned(
              bottom: 12,
              right: 16,
              child: SizedBox(
                height: 36,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text(
                    "DÒ BIT",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    elevation: 4,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: _transferToScanner,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- LAYER TREE PANEL WIDGET (CÂY THƯ MỤC) ---
  Widget _buildLayerTreePanel() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      left: _showLayerPanel ? 0 : -200,
      top: 400,
      bottom: 0, // Chạm thanh công cụ
      width: 200, // Thu nhỏ từ 240 xuống 180
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.97),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(10),
            bottomRight: Radius.circular(10),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 6,
              offset: const Offset(2, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header - Tiêu đề cây thư mục
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: primaryDark,
                borderRadius: const BorderRadius.only(topRight: Radius.circular(10)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_tree, color: Colors.white70, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    'Quản lý lớp',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  // NÚT RELOAD - Tải lại ranh giới & dữ liệu đường
                  if (_currentBounds != null)
                    InkWell(
                      onTap: () async {
                        // 1. Reload Dữ liệu đường (vn_roads.json -> cache)
                        await RoadAssetService().reloadFromAssets();
                        
                        // 2. Reload Ranh giới từ KMZ
                        // skipFitCamera: true để KHÔNG bay camera khi reload
                        _autoDetectProvincesFromKMZ(_currentBounds!, skipFitCamera: true);
                        
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Đã làm mới dữ liệu & ranh giới!"),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.refresh, color: Colors.white70, size: 16),
                      ),
                    ),
                  InkWell(
                    onTap: () => setState(() => _showLayerPanel = false),
                    child: const Icon(Icons.close, color: Colors.white70, size: 16),
                  ),
                ],
              ),
            ),
            
            // [MỚI] Thông tin kích thước Sa Bàn
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                border: Border(bottom: BorderSide(color: Colors.blue.shade200, width: 0.5)),
              ),
              child: Row(
                children: [
                  Icon(Icons.aspect_ratio, size: 14, color: Colors.blue[700]),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_renderWidth.toInt()}x${_renderHeight.toInt()} cm  |  ${cols}x$rows Tấm',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            // Checkbox chọn bộ dữ liệu 2025 (34 tỉnh sau sáp nhập)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _useMerged2025 ? Colors.orange.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.08),
                border: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 0.5)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: _useMerged2025,
                      activeColor: Colors.orange,
                      onChanged: (v) {
                        setState(() {
                          _useMerged2025 = v ?? false;
                          
                          // [SỬA] Tắt tất cả layer ranh giới đang bật TRƯỚC KHI load dữ liệu mới
                          // Xóa tất cả layer boundary_ và border_ khỏi selectedLayerIds
                          _selectedLayerIds.removeWhere((id) => 
                              id.startsWith('boundary_') || id.startsWith('border_'));
                          
                          // Xóa polylines đang hiển thị liên quan đến ranh giới
                          _displayedPolylines.clear();
                          _hasRoadSelected = false;
                        });
                        
                        // Reload ranh giới nếu có bounds
                        if (_currentBounds != null) {
                          // Clear cache ranh giới để reload với bộ dữ liệu mới
                          _cachedRoads.removeWhere((r) => r.type == 'boundary');
                          _populateLayerGroups();
                          _autoDetectProvincesFromKMZ(_currentBounds!, skipFitCamera: true);
                        }
                        
                        _saveAllSettings();
                      },
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _useMerged2025 ? 'Địa giới hành chính mới' : 'Địa giới hành chính cũ',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: _useMerged2025 ? Colors.orange[800] : Colors.grey[700],
                      ),
                    ),
                  ),
                  Icon(
                    _useMerged2025 ? Icons.new_releases : Icons.map,
                    size: 14,
                    color: _useMerged2025 ? Colors.orange : Colors.grey,
                  ),
                ],
              ),
            ),
            // Tree Content
            Expanded(
              child: _layerGroups.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Chưa có dữ liệu\nNhấn "Dữ liệu" để tải',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 11),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: _layerGroups.map((group) {
                        bool allSelected = group.items.isNotEmpty &&
                            group.items.every((i) => _selectedLayerIds.contains(i.id));
                        bool anySelected = group.items.any((i) => _selectedLayerIds.contains(i.id));
                        
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ▸ Folder Header
                            InkWell(
                              onTap: () => setState(() => group.isExpanded = !group.isExpanded),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                child: Row(
                                  children: [
                                    Icon(
                                      group.isExpanded ? Icons.arrow_drop_down : Icons.arrow_right,
                                      size: 20,
                                      color: Colors.grey[600],
                                    ),
                                    if (group.items.isNotEmpty)
                                      SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: Checkbox(
                                          value: allSelected ? true : (anySelected ? null : false),
                                          tristate: true,
                                          activeColor: primaryDark,
                                          onChanged: (v) => _onGroupToggled(group, !allSelected),
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      group.isExpanded ? Icons.folder_open : Icons.folder,
                                      size: 16,
                                      color: Colors.amber[700],
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${group.name} (${group.items.length})',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: anySelected ? primaryDark : Colors.black87,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            
                            // ├─ Items (files)
                            if (group.isExpanded)
                              ...group.items.asMap().entries.map((entry) {
                                int idx = entry.key;
                                var item = entry.value;
                                bool isLast = idx == group.items.length - 1;
                                bool isSelected = _selectedLayerIds.contains(item.id);
                                
                                // [MỚI] Long press để xóa (chỉ cho đường trong panel)
                                bool isRoad = item.id.startsWith('road_');
                                
                                return InkWell(
                                  onTap: () => _onLayerToggled(item.id, !isSelected),
                                  onLongPress: isRoad ? () {
                                    _showDeleteRoadDialog(item.name);
                                  } : null,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 20),
                                    child: Row(
                                      children: [
                                        // Tree line
                                        SizedBox(
                                          width: 16,
                                          child: Text(
                                            isLast ? '└─' : '├─',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[800],
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: Checkbox(
                                            value: isSelected,
                                            activeColor: primaryDark,
                                            onChanged: (v) => _onLayerToggled(item.id, v ?? false),
                                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            visualDensity: VisualDensity.compact,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            item.name,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                              color: isSelected ? primaryDark : Colors.black87,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            
                            // Empty folder
                            if (group.isExpanded && group.items.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 40, top: 2, bottom: 2),
                                child: Text(
                                  '(Tìm kiếm để thêm)',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                    color: Colors.grey[400],
                                  ),
                                ),
                              ),
                          ],
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // Nút mở lại panel khi đã ẩn (góc trên trái)
  Widget _buildLayerPanelToggle() {
    if (_showLayerPanel) return const SizedBox.shrink();
    return Positioned(
      left: 10,
      top: 410, // Khớp với vị trí panel mới
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(25),
        color: Colors.white,
        child: InkWell(
          onTap: () => setState(() => _showLayerPanel = true),
          borderRadius: BorderRadius.circular(25),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: primaryDark.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.layers, color: primaryDark, size: 18),
                SizedBox(width: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInput(String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 12,
        ),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
