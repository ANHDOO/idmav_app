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
import 'package:share_plus/share_plus.dart';
import 'scanner_page.dart';

const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

// --- MODEL DỮ LIỆU (GIỮ NGUYÊN) ---
class RoadData {
  final String id;
  final String name;
  final String ref;
  final String type; // 'motorway', 'trunk', 'boundary'
  final List<LatLng> points;
  final int colorValue;
  final double width;
  final bool isMaritime; // [MỚI] Đánh dấu biên giới biển

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

// --- [MỚI] LAYER DATA STRUCTURES ---
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
  State<MatrixMapPage> createState() => _MatrixMapPageState();
}

class _MatrixMapPageState extends State<MatrixMapPage> {
  // --- CONTROLLER ---
  final TextEditingController _widthCtrl = TextEditingController(text: "600");
  final TextEditingController _heightCtrl = TextEditingController(text: "700");
  final TextEditingController _searchCtrl = TextEditingController();
  final MapController _mapController = MapController();

  // --- DATA ---
  double _renderWidth = 600;
  double _renderHeight = 700;
  int _selectedTileSize = 50;

  List<Polyline> _kmzPolylines = [];
  List<RoadData> _cachedRoads = [];
  List<Polyline> _displayedPolylines = [];

  // [MỚI] Layer Tree Data
  List<LayerGroup> _layerGroups = [];
  bool _showLayerPanel = true;
  Set<String> _selectedLayerIds = {}; // IDs của các layer đang được bật

  List<Polygon> _gridPolygons = [];
  List<Marker> _gridMarkers = [];
  LatLngBounds? _currentBounds;

  // [MỚI] Lưu trữ ID của từng tấm. Key: "A1", Value: "26"
  // Dùng để map giữa tọa độ lưới và ID phần cứng
  Map<String, String> _tileControlIds = {};

  // [MỚI] Đường do người dùng thêm thủ công vào panel
  // Key: Tên chuẩn (VD: "QL1", "CT.01"), Value: polylines đã vẽ
  Map<String, List<Polyline>> _manualAddedRoads = {};

  // UI Loading State
  String? _loadingStatus;

  bool _showGrid = true;
  bool _isMapReady = false;
  bool _isSatelliteMode = false;

  // Tùy chọn tìm kiếm
  bool _useOnlineSearch = false;
  
  // 0: Đường đi, 1: Ranh giới (Nominatim), 2: Biên giới (Overpass)
  int _searchMode = 0; 
  bool _filterSea = true; // Lọc biên giới biển

  LatLng _savedCenter = const LatLng(21.0285, 105.8542);
  double _savedZoom = 10.0;

  int get cols => (_renderWidth / _selectedTileSize).ceil();
  int get rows => (_renderHeight / _selectedTileSize).ceil();

  @override
  void initState() {
    super.initState();
    _loadAllSettings();
    _loadCachedRoadsFromFile();
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
      _isSatelliteMode = prefs.getBool('map_satellite_mode') ?? false;

      // [MỚI] Load ID các tấm đã lưu
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
    await prefs.setBool('map_satellite_mode', _isSatelliteMode);

    // [MỚI] Lưu ID các tấm
    await prefs.setString('map_tile_ids', jsonEncode(_tileControlIds));

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

  // --- FILE SYSTEM (GIỮ NGUYÊN) ---
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
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/idmav_roads.json');
      if (await file.exists()) {
        String jsonStr = await file.readAsString();
        List<dynamic> jsonList = jsonDecode(jsonStr);
        setState(() {
          _cachedRoads = jsonList.map((e) => RoadData.fromJson(e)).toList();
        });
      }
      // Load đường thủ công
      await _loadManualRoadsFromFile();
      _populateLayerGroups(); // Populate layer tree sau khi load data
    } catch (e) {
      debugPrint("Lỗi đọc file: $e");
    }
  }

  // [MỚI] Lưu đường thủ công vào file
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
        }).toList();
      });
      
      await file.writeAsString(jsonEncode(dataToSave));
      debugPrint("✅ Đã lưu ${_manualAddedRoads.length} đường thủ công");
    } catch (e) {
      debugPrint("Lỗi lưu đường thủ công: $e");
    }
  }

  // [MỚI] Load đường thủ công từ file
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
            );
          }).toList();
          
          _manualAddedRoads[name] = polylines;
          // Auto select saved roads
          _selectedLayerIds.add('road_$name');
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
          name: 'Biên giới Quốc gia',
          items: borderItems,
          isExpanded: true,
        ),
        LayerGroup(
          name: 'Ranh giới Tỉnh/TP',
          items: boundaryItems,
          isExpanded: true,
        ),
        LayerGroup(
          name: 'Quốc lộ & Cao tốc',
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
      } else {
        _selectedLayerIds.remove(layerId);
      }
    });
    _updateDisplayedPolylinesFromLayers();
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
    _updateDisplayedPolylinesFromLayers();
  }

  /// Cập nhật polylines hiển thị dựa trên layers đã chọn
  void _updateDisplayedPolylinesFromLayers() {
    List<Polyline> newPolylines = [];
    
    for (var layerId in _selectedLayerIds) {
      // Xử lý Biên giới Việt Nam
      if (layerId == 'border_vietnam') {
        for (var road in _cachedRoads) {
          if (road.type == 'boundary') {
            String lowerName = road.name.toLowerCase();
            if (lowerName.contains('việt nam') || lowerName.contains('vietnam')) {
              // Bỏ qua biên giới biển theo tên
              if (_isMaritimeBoundary(road.name)) continue;
              
              List<LatLng> renderPoints = _simplifyForRendering(road.points);
              newPolylines.add(
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
            newPolylines.add(
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
          newPolylines.addAll(_manualAddedRoads[roadName]!);
        }
      }
    }

    setState(() {
      _displayedPolylines = newPolylines;
    });

    // // Fit camera nếu có polylines mới
    // if (newPolylines.isNotEmpty) {
    //   _fitCameraToPolylines(newPolylines);
    // }
  }

  // --- EXPORT & IMPORT (GIỮ NGUYÊN) ---
  Future<void> _exportData() async {
    if (_cachedRoads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Không có dữ liệu để xuất!")),
      );
      return;
    }
    try {
      String jsonStr = jsonEncode(_cachedRoads.map((e) => e.toJson()).toList());
      final tempDir = await getTemporaryDirectory();
      final file = File(
        '${tempDir.path}/BanDo_Export_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(jsonStr);
      final result = await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Dữ liệu bản đồ IDMAV');
      if (result.status == ShareResultStatus.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Đã xuất dữ liệu thành công!")),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Lỗi xuất file: $e")));
    }
  }

  Future<void> _importData() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result != null) {
        File file = File(result.files.single.path!);
        String jsonStr = await file.readAsString();
        List<dynamic> jsonList = jsonDecode(jsonStr);
        List<RoadData> importedItems = jsonList
            .map((e) => RoadData.fromJson(e))
            .toList();
        await _mergeAndSave(importedItems, "Dữ liệu Import");
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Lỗi nạp file: $e")));
    }
  }

  Future<void> _clearAllData() async {
    try {
      setState(() {
        _cachedRoads.clear();
        _displayedPolylines.clear();
      });
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/idmav_roads.json');
      if (await file.exists()) await file.delete();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Đã xóa sạch dữ liệu Cache!")),
      );
    } catch (e) {
      debugPrint("Lỗi xóa: $e");
    }
  }

  // --- HELPER FUNCTIONS (GIỮ NGUYÊN) ---
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

  void _fitCameraToPolylines(List<Polyline> polylines) {
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
      LatLngBounds bounds = LatLngBounds(
        LatLng(minLat, minLng),
        LatLng(maxLat, maxLng),
      );
      // Thêm padding trái để tránh panel che
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.only(
          left: 200, // Panel width + margin
          top: 50,
          right: 50,
          bottom: 100,
        )),
      );
    }
  }

  String _createSuperFlexibleRegex(String input) {
    String clean = input.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (clean.isEmpty) return input;
    List<String> chars = clean.split('');
    String core = chars.join(r'[.\\-\\s]*');
    return '(^|[^a-zA-Z0-9])$core(\$|[^a-zA-Z0-9])';
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

  // --- DOWNLOAD TURBO MODE (GIỮ NGUYÊN) ---
  Future<void> _incrementalDownload(
    String label,
    String query,
    LatLngBounds bounds,
  ) async {
    List<String> servers = [
      'https://lz4.overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://api.openstreetmap.fr/oapi/interpreter',
    ];
    try {
      setState(() => _loadingStatus = "Đang tải dữ liệu... (Đa luồng)");
      final response = await _raceToFindServer(servers, query);

      if (response.statusCode == 200) {
        await Future.delayed(Duration.zero, () async {
          final data = jsonDecode(response.body);
          if (data['elements'] == null) return;

          // [PASS 1] Cache tags của tất cả các Way
          // Key: Way ID, Value: Map<String, dynamic> tags
          Map<String, Map<String, dynamic>> wayTagsCache = {};
          for (var element in data['elements']) {
            if (element['type'] == 'way' && element['tags'] != null) {
              wayTagsCache[element['id'].toString()] = element['tags'];
            }
          }

          List<RoadData> tempItems = [];
          for (var element in data['elements']) {
            // Xử lý WAY (Đường đi)
            if (element['type'] == 'way' && element['geometry'] != null) {
              // Chỉ lấy nếu có tag highway (để tránh lấy nhầm các đoạn biên giới dạng way)
              if (element['tags'] != null && element['tags']['highway'] != null) {
                List<LatLng> pts = [];
                for (var geom in element['geometry']) {
                  pts.add(LatLng(geom['lat'], geom['lon']));
                }
                List<LatLng> clipped = [];
                for (var p in pts) if (bounds.contains(p)) clipped.add(p);
                
                if (clipped.isNotEmpty) {
                  String type = 'trunk';
                  int colorVal = Colors.orange.value;
                  double width = 6.0;
                  if (element['tags']?['highway'] == 'motorway') {
                    type = 'motorway';
                    colorVal = Colors.redAccent.value;
                    width = 8.0;
                  }
                  tempItems.add(
                    RoadData(
                      id: element['id'].toString(),
                      name: element['tags']?['name'] ?? "",
                      ref: element['tags']?['ref'] ?? "",
                      type: type,
                      points: _simplifyPoints(clipped, threshold: 0.001),
                      colorValue: colorVal,
                      width: width,
                    ),
                  );
                }
              }
            } 
            // Xử lý RELATION (Ranh giới)
            else if (element['type'] == 'relation' && element['members'] != null) {
              String rName = element['tags']?['name'] ?? "";
              bool relationIsMaritime = element['tags']?['maritime'] == 'yes';

              for (var member in element['members']) {
                if (member['type'] == 'way' && member['geometry'] != null) {
                  List<LatLng> mPts = [];
                  for (var geom in member['geometry']) {
                    mPts.add(LatLng(geom['lat'], geom['lon']));
                  }
                  List<LatLng> clipped = [];
                  for (var p in mPts) if (bounds.contains(p)) clipped.add(p);
                  
                  if (clipped.isNotEmpty) {
                    // Check maritime từ cache tags của way
                    String memberRef = member['ref'].toString();
                    Map<String, dynamic>? memberTags = wayTagsCache[memberRef];
                    bool memberIsMaritime = memberTags?['maritime'] == 'yes';

                    // Là biển nếu relation hoặc chính đoạn way đó là maritime
                    bool isMaritime = relationIsMaritime || memberIsMaritime;

                    tempItems.add(
                      RoadData(
                        id: "${element['id']}_${member['ref'] ?? 0}_${Random().nextInt(9999)}",
                        name: rName,
                        ref: "",
                        type: 'boundary',
                        points: _simplifyPoints(clipped, threshold: 0.0015),
                        colorValue: Colors.purpleAccent.value,
                        width: 4.0,
                        isMaritime: isMaritime,
                      ),
                    );
                  }
                }
              }
            }
          }
          await _mergeAndSave(tempItems, label);
        });
      }
    } catch (e) {
      debugPrint("Lỗi tải $label: $e");
    }
  }

  Future<void> _downloadDataInFrame({
    bool dlMotorway = true,
    bool dlTrunk = true,
  }) async {
    LatLngBounds targetBounds =
        _currentBounds ?? _mapController.camera.visibleBounds;
    setState(() {
      _loadingStatus = "Bắt đầu tải Đường bộ (Offline)...";
      _displayedPolylines.clear();
    });

    String bbox =
        '${targetBounds.south},${targetBounds.west},${targetBounds.north},${targetBounds.east}';

    List<Future> tasks = [];
    // [VN FILTER] Chỉ tải trong lãnh thổ Việt Nam (Area ID: 3600049915)
    String areaFilter = 'area(3600049915)->.searchArea;';
    
    if (dlMotorway) {
      String qMotorway =
          '[out:json][timeout:40]; $areaFilter way["highway"="motorway"](area.searchArea)($bbox); (._;>;); out geom;';
      tasks.add(_incrementalDownload("Cao tốc", qMotorway, targetBounds));
    }
    if (dlTrunk) {
      String qTrunk =
          '[out:json][timeout:40]; $areaFilter way["highway"="trunk"](area.searchArea)($bbox); (._;>;); out geom;';
      tasks.add(_incrementalDownload("Quốc lộ", qTrunk, targetBounds));
    }

    if (tasks.isEmpty) {
      setState(() => _loadingStatus = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bạn chưa chọn loại dữ liệu nào để tải!")),
      );
      return;
    }

    await Future.wait(tasks);
    setState(() => _loadingStatus = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Hoàn tất! Dữ liệu đường bộ đã lưu vào kho Offline.")),
    );
  }

  // --- [MỚI] TỰ ĐỘNG PHÁT HIỆN CÁC TỈNH TRONG KHU VỰC KMZ ---
  // Bước 1: Dùng Overpass tìm tên tỉnh trong lãnh thổ VN
  // Bước 2: Dùng Nominatim tải geometry từng tỉnh (nhanh hơn)
  void _autoDetectProvincesFromKMZ(LatLngBounds bounds) {
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
        debugPrint("📍 Bắt đầu tìm tỉnh trong KMZ bounds...");
        
        // BƯỚC 1: Dùng Overpass để tìm danh sách tỉnh/thành trong bounds
        // Chỉ query các relation NẰM TRONG area VN (3600049915)
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
                  
                  // Biên giới quốc gia VN
                  if (adminLevel == "2") {
                    String lowerName = name.toLowerCase();
                    if (lowerName.contains('việt nam') || lowerName.contains('vietnam')) {
                      hasVietnamBorder = true;
                    }
                    continue; // Không thêm vào provinceNames
                  }
                  
                  // Tỉnh/thành (admin_level=4)
                  // Filter: Chỉ lấy tên tiếng Việt hoặc có dấu
                  // Loại bỏ các tỉnh nước ngoài (Trung Quốc, Lào, Campuchia)
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

        debugPrint("✅ Overpass: hasVietnamBorder=$hasVietnamBorder, tỉnh=${provinceNames.length}: ${provinceNames.join(', ')}");

        if (provinceNames.isEmpty && !hasVietnamBorder) {
          debugPrint("❌ Không tìm thấy tỉnh/biên giới VN nào trong KMZ bounds");
          return;
        }

        // BƯỚC 2: Dùng Nominatim để tải geometry
        List<RoadData> allBoundaries = [];
        
        // Tải biên giới VN trước
        if (hasVietnamBorder) {
          await _fetchProvinceBoundaryNominatim("Việt Nam", bounds, allBoundaries);
        }
        
        // Tải các tỉnh SONG SONG (batch 5 cùng lúc để nhanh hơn)
        List<String> provinceList = provinceNames.toList();
        for (int i = 0; i < provinceList.length; i += 5) {
          if (!mounted) return;
          
          int end = (i + 5 > provinceList.length) ? provinceList.length : i + 5;
          List<String> batch = provinceList.sublist(i, end);
          
          // Tải song song batch
          await Future.wait(
            batch.map((name) => _fetchProvinceBoundaryNominatim(name, bounds, allBoundaries)),
          );
          
          // Rate limit giữa các batch
          if (end < provinceList.length) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }

        // Merge và cập nhật UI nếu có dữ liệu
        if (allBoundaries.isNotEmpty && mounted) {
          await _mergeAndSave(allBoundaries, "Ranh giới từ KMZ");
          
          if (mounted) {
            setState(() {
              _populateLayerGroups();
            });
          }
          
          debugPrint("✅ Đã tải xong ${allBoundaries.length} đoạn ranh giới");
        }
      } catch (e) {
        debugPrint("Lỗi auto-detect provinces: $e");
      }
    });
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
  Future<void> _searchBoundaryNominatim(String keyword) async {
    setState(() {
      _loadingStatus = "Đang tìm ranh giới qua Nominatim...";
      _displayedPolylines.clear();
    });

    try {
      // Gọi Nominatim API
      String url = Uri.encodeFull(
        "https://nominatim.openstreetmap.org/search?q=$keyword&format=json&polygon_geojson=1&countrycodes=vn&limit=1",
      );
      
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'iDMAV_Mobile_App'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Không tìm thấy ranh giới!")),
          );
          setState(() => _loadingStatus = null);
          return;
        }

        var place = data[0];
        var geojson = place['geojson'];
        
        if (geojson == null || geojson['coordinates'] == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Ranh giới này không có dữ liệu polygon!")),
          );
          setState(() => _loadingStatus = null);
          return;
        }

        List<Polyline> boundaryLines = [];
        String type = geojson['type'];

        // Xử lý Polygon hoặc MultiPolygon
        if (type == 'Polygon') {
          var coords = geojson['coordinates'][0]; // Outer ring
          List<LatLng> points = [];
          for (var coord in coords) {
            points.add(LatLng(coord[1], coord[0])); // [lng, lat] -> LatLng(lat, lng)
          }
          if (points.length > 2) {
            boundaryLines.add(
              Polyline(
                points: _simplifyPoints(points, threshold: 0.002),
                color: Colors.purpleAccent,
                strokeWidth: 4.0,
                isDotted: true,
              ),
            );
          }
        } else if (type == 'MultiPolygon') {
          for (var polygon in geojson['coordinates']) {
            var coords = polygon[0]; // Outer ring của mỗi polygon
            List<LatLng> points = [];
            for (var coord in coords) {
              points.add(LatLng(coord[1], coord[0]));
            }
            if (points.length > 2) {
              boundaryLines.add(
                Polyline(
                  points: _simplifyPoints(points, threshold: 0.002),
                  color: Colors.purpleAccent,
                  strokeWidth: 4.0,
                  isDotted: true,
                ),
              );
            }
          }
        }

        setState(() => _displayedPolylines = boundaryLines);
        
        if (boundaryLines.isNotEmpty) {
          _fitCameraToPolylines(boundaryLines);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("✅ Tìm thấy: ${place['display_name']}"),
              backgroundColor: Colors.purple,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Lỗi Nominatim: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi khi tìm ranh giới: $e")),
      );
    } finally {
      setState(() => _loadingStatus = null);
    }
  }
  Future<void> _searchOnline() async {
    String rawKeyword = _searchCtrl.text.trim();
    if (rawKeyword.isEmpty) return;

    // Mode 1: Ranh giới -> Dùng Nominatim (Nhanh)
    if (_searchMode == 1) {
      await _searchBoundaryNominatim(rawKeyword);
      return;
    }

    // Mode 2: Biên giới -> Dùng Overpass (Chi tiết, có lọc biển)
    if (_searchMode == 2) {
      await _searchBorderOverpass(rawKeyword);
      return;
    }

    // Mode 0: Đường đi -> Dùng Overpass như cũ
    LatLngBounds searchBounds =
        _currentBounds ?? _mapController.camera.visibleBounds;
    setState(() {
      _loadingStatus = "Đang tìm kiếm dữ liệu online...";
      _displayedPolylines.clear();
    });

    double buffer = 0.005;
    String bbox =
        '${searchBounds.south - buffer},${searchBounds.west - buffer},${searchBounds.north + buffer},${searchBounds.east + buffer}';
    String flexibleRegex = _createSuperFlexibleRegex(rawKeyword);
    String query = """
        [out:json][timeout:25];
        area(3600049915)->.searchArea;
        (
          way["highway"~"^(motorway|trunk|primary|secondary)"]["highway"!~"_link"]["ref"~"$flexibleRegex",i](area.searchArea)($bbox);
          way["highway"~"^(motorway|trunk|primary|secondary)"]["highway"!~"_link"]["name"~"$flexibleRegex",i](area.searchArea)($bbox);
        );
        out geom;
      """;

    List<String> servers = [
      'https://lz4.overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://api.openstreetmap.fr/oapi/interpreter',
    ];

    try {
      final response = await _raceToFindServer(servers, query);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<Polyline> foundLines = [];
        if (data['elements'] != null) {
          for (var element in data['elements']) {
            // Xử lý way trực tiếp (cho đường)
            if (element['type'] == 'way' && element['geometry'] != null) {
              List<LatLng> pts = [];
              for (var geom in element['geometry'])
                pts.add(LatLng(geom['lat'], geom['lon']));
              List<LatLng> simplified = _simplifyPoints(pts, threshold: 0.001);
              foundLines.add(
                Polyline(
                  points: simplified,
                  color: (_searchMode != 0)
                      ? Colors.purpleAccent
                      : Colors.blueAccent,
                  strokeWidth: (_searchMode != 0) ? 4.0 : 7.0,
                  borderColor: Colors.white,
                  borderStrokeWidth: (_searchMode != 0) ? 0 : 2.0,
                  isDotted: (_searchMode != 0),
                ),
              );
            }
            // Xử lý relation members (cho ranh giới)
            else if (element['type'] == 'relation' && element['members'] != null) {
              for (var member in element['members']) {
                if (member['type'] == 'way' && member['geometry'] != null) {
                  List<LatLng> pts = [];
                  for (var geom in member['geometry'])
                    pts.add(LatLng(geom['lat'], geom['lon']));
                  List<LatLng> simplified = _simplifyPoints(pts, threshold: 0.0015);
                  foundLines.add(
                    Polyline(
                      points: simplified,
                      color: Colors.purpleAccent,
                      strokeWidth: 4.0,
                      borderColor: Colors.white,
                      borderStrokeWidth: 0,
                      isDotted: true,
                    ),
                  );
                }
              }
            }
          }
        }
        
        // [TỐI ƯU 1] Lọc bớt các nhánh nhiễu
        List<Polyline> filteredLines = _filterRelevantSegments(foundLines);

        // [TỐI ƯU 2] Cắt gọn trong khung
        LatLngBounds bounds = _currentBounds ?? _mapController.camera.visibleBounds;
        List<Polyline> clippedLines = _clipPolylinesToBounds(filteredLines, bounds);
        
        setState(() => _displayedPolylines = clippedLines);
        if (clippedLines.isNotEmpty) {
          // [KHÔNG thêm vào panel từ Online - chỉ thêm từ Offline với dialog xác nhận]
          
          _fitCameraToPolylines(clippedLines);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "✅ Tìm thấy ${clippedLines.length} kết quả (Đã lọc & Cắt)",
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Không tìm thấy trên các trục đường chính!"),
            ),
          );
        }
        }
      }
     catch (e) {
      debugPrint("Lỗi: $e");
    } finally {
      setState(() => _loadingStatus = null);
    }
  }

  Future<http.Response> _raceToFindServer(List<String> urls, String query) {
    final completer = Completer<http.Response>();
    int failureCount = 0;
    for (var url in urls) {
      http
          .post(Uri.parse(url), body: query)
          .timeout(const Duration(seconds: 40))
          .then((response) {
            if (!completer.isCompleted && response.statusCode == 200)
              completer.complete(response);
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

  bool _isSmartMatch(String rawSource, String rawKeyword) {
    String s = rawSource.toLowerCase().replaceAll(RegExp(r'[.\-\s]'), '');
    String k = rawKeyword.toLowerCase().replaceAll(RegExp(r'[.\-\s]'), '');
    if (k.isEmpty) return false;
    int index = s.indexOf(k);
    if (index == -1) return false;
    if (index + k.length < s.length) {
      String charAfter = s[index + k.length];
      if (RegExp(r'[a-z0-9]').hasMatch(charAfter)) return false;
    }
    return true;
  }

  void _searchOffline() {
    String rawKeyword = _searchCtrl.text.trim();
    if (rawKeyword.isEmpty) {
      setState(() => _displayedPolylines = []);
      return;
    }

    List<Polyline> lines = [];
    for (var road in _cachedRoads) {
      if (_searchMode != 0) {
        if (road.type != 'boundary') continue;
        // Lọc biển offline
        if (_filterSea && road.isMaritime) continue;
      } else {
        if (road.type == 'boundary') continue;
      }

      bool matchName = _isSmartMatch(road.name, rawKeyword);
      bool matchRef = _isSmartMatch(road.ref, rawKeyword);

      if (matchName || matchRef) {
        List<LatLng> renderPoints = _simplifyForRendering(road.points);
        double renderWidth = lines.length > 20 ? road.width * 0.7 : road.width;
        lines.add(
          Polyline(
            points: renderPoints,
            color: road.type == 'boundary'
                ? Colors.purpleAccent
                : (_isSatelliteMode
                      ? Color(road.colorValue)
                      : Color(road.colorValue).withOpacity(0.8)),
            strokeWidth: renderWidth,
            borderStrokeWidth: 0,
            strokeCap: StrokeCap.round,
            strokeJoin: StrokeJoin.round,
            isDotted: road.type == 'boundary',
          ),
        );
      }
    }

    // [TỐI ƯU] Áp dụng lọc nhiễu và cắt gọn giống Online
    // 1. Lọc nhiễu (Connected Components)
    List<Polyline> filteredLines = _filterRelevantSegments(lines);

    // 2. Cắt gọn theo khung nhìn hiện tại
    LatLngBounds bounds = _currentBounds ?? _mapController.camera.visibleBounds;
    List<Polyline> clippedLines = _clipPolylinesToBounds(filteredLines, bounds);

    setState(() => _displayedPolylines = clippedLines);
    if (clippedLines.isNotEmpty) {
      _fitCameraToPolylines(clippedLines);
      
      // [MỚI] Hiển dialog hỏi người dùng có muốn thêm vào Panel không (chỉ cho đường)
      if (_searchMode == 0) {
        String searchedRef = rawKeyword.toUpperCase();
        _showAddToPanelDialog(searchedRef, clippedLines);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Offline: Tìm thấy ${clippedLines.length} đoạn (Đã lọc & Cắt)"),
            duration: const Duration(milliseconds: 800),
          ),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Không tìm thấy trong Cache (Nhập chính xác tên/mã)"),
        ),
      );
    }
  }

  // [MỚI] Dialog hỏi thêm đường vào Panel
  void _showAddToPanelDialog(String roadName, List<Polyline> polylines) {
    // Check đã có trong panel chưa
    if (_manualAddedRoads.containsKey(roadName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("'$roadName' đã có trong Panel rồi"),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text("Thêm vào Panel?"),
        content: Text(
          "Tìm thấy ${polylines.length} đoạn đường '$roadName'.\n\nBạn có muốn thêm vào Panel \"Quốc lộ & Cao tốc\" không?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Không"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryDark,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              // Thêm vào panel với polylines đã vẽ
              _manualAddedRoads[roadName] = List.from(polylines);
              _populateLayerGroups();
              // Tự động bật hiển thị
              _selectedLayerIds.add('road_$roadName');
              // Lưu vào file
              _saveManualRoadsToFile();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text("✅ Đã thêm '$roadName' vào Panel"),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text("Thêm"),
          ),
        ],
      ),
    );
  }

  // [MỚI] Dialog xác nhận xóa đường khỏi Panel
  void _showDeleteRoadDialog(String roadName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text("Xóa khỏi Panel?"),
        content: Text(
          "Bạn có muốn xóa '$roadName' khỏi Panel không?",
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
              // Xóa khỏi panel
              _manualAddedRoads.remove(roadName);
              _selectedLayerIds.remove('road_$roadName');
              _populateLayerGroups();
              // Lưu vào file
              _saveManualRoadsToFile();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text("🗑️ Đã xóa '$roadName' khỏi Panel"),
                  backgroundColor: Colors.orange,
                ),
              );
            },
            child: const Text("Xóa"),
          ),
        ],
      ),
    );
  }

  // --- [TÍNH NĂNG MỚI] LỌC NHIỄU (CONNECTED COMPONENTS) ---
  List<Polyline> _filterRelevantSegments(List<Polyline> input) {
    if (input.isEmpty) return [];

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
    // Hai đoạn được coi là nối nhau nếu đầu mút cách nhau < 50m
    double thresholdMeters = 50.0;
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

    // 6. Giữ lại nhóm lớn nhất và các nhóm "đủ lớn" (>= 20% nhóm lớn nhất)
    // Để tránh mất các đoạn đường bị đứt quãng do dữ liệu bản đồ
    double maxLength = scoredComponents[0]['length'];
    List<Polyline> result = [];
    
    for (var comp in scoredComponents) {
      if ((comp['length'] as double) > maxLength * 0.2) {
        for (int idx in comp['indices']) {
          result.add(input[idx]);
        }
      }
    }

    return result;
  }

  // --- [TÍNH NĂNG MỚI] AUTO DETECT SEARCH MODE ---
  void _detectAndSwitchSearchMode(String input) {
    String lower = input.toLowerCase();
    
    // Từ khóa Ranh giới / Biên giới
    List<String> boundaryKeywords = [
      "tỉnh", "thành phố", "quận", "huyện", "thị xã","thủ đô",
      "hà nội", "hồ chí minh", "đà nẵng", "hải phòng", "cần thơ",
      "thái bình", "nam định", "ninh bình", "hà nam",
      "hưng yên", "hải dương", "vĩnh phúc", "bắc ninh",
      "bắc giang", "thái nguyên", "phú thọ", "hòa bình"
    ];

    List<String> borderKeywords = ["việt nam", "biên giới", "lãnh thổ", "trung quốc", "lào", "campuchia"];

    // Từ khóa Đường
    List<String> roadKeywords = [
      "ct", "ql", "tl", "đt", "đường", "phố", "cao tốc", "quốc lộ"
    ];

    bool isBoundary = false;
    bool isBorder = false;
    bool isRoad = false;

    for (var k in boundaryKeywords) {
      if (lower.contains(k)) {
        isBoundary = true;
        break;
      }
    }

    for (var k in borderKeywords) {
      if (lower.contains(k)) {
        isBorder = true;
        break;
      }
    }

    for (var k in roadKeywords) {
      if (lower.contains(k)) {
        isRoad = true;
        break;
      }
    }
    
    if (isBorder && _searchMode != 2) {
       setState(() => _searchMode = 2); // Switch to Border
       ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🔄 Đã tự động chuyển sang tìm Biên giới"),
            duration: Duration(milliseconds: 1500),
            backgroundColor: Colors.purple,
          ),
        );
    } else if (isBoundary && !isBorder && _searchMode != 1) {
       setState(() => _searchMode = 1); // Switch to Boundary
       ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🔄 Đã tự động chuyển sang tìm Ranh giới"),
            duration: Duration(milliseconds: 1500),
            backgroundColor: Colors.purple,
          ),
        );
    } else if (isRoad && _searchMode != 0) {
        setState(() => _searchMode = 0); // Switch to Road
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🔄 Đã tự động chuyển sang tìm Đường đi"),
            duration: Duration(milliseconds: 1500),
            backgroundColor: Colors.orange,
          ),
        );
    }
  }

  void _executeSearch() {
    // 1. Auto detect trước
    _detectAndSwitchSearchMode(_searchCtrl.text.trim());

    // 2. Thực thi tìm kiếm như cũ
    if (_useOnlineSearch)
      _searchOnline();
    else {
      if (_cachedRoads.isEmpty)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Kho dữ liệu trống. Hãy tải trước!")),
        );
      else
        _searchOffline();
    }
  }

  // --- UI DIALOGS (GIỮ NGUYÊN) ---
  // --- [TÍNH NĂNG MỚI] TÌM BIÊN GIỚI OVERPASS (LỌC BIỂN) ---
  Future<void> _searchBorderOverpass(String keyword) async {
    LatLngBounds searchBounds =
        _currentBounds ?? _mapController.camera.visibleBounds;
    setState(() {
      _loadingStatus = "Đang tìm biên giới ${_filterSea ? '(Lọc biển)' : ''}...";
      _displayedPolylines.clear();
    });

    double buffer = 0.005;
    String bbox =
        '${searchBounds.south - buffer},${searchBounds.west - buffer},${searchBounds.north + buffer},${searchBounds.east + buffer}';
    
    // Query: Tìm relation (tỉnh/nước) -> Lấy way trong bbox -> Lọc maritime!=yes nếu cần
    String maritimeFilter = _filterSea ? '["maritime"!="yes"]' : '';
    String query = """
        [out:json][timeout:60];
        area(3600049915)->.searchArea;
        relation["boundary"="administrative"]["name"~"$keyword",i](area.searchArea)($bbox);
        way(r)($bbox)$maritimeFilter;
        (._;>;);
        out geom;
      """;

    List<String> servers = [
      'https://lz4.overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://api.openstreetmap.fr/oapi/interpreter',
    ];

    try {
      final response = await _raceToFindServer(servers, query);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<Polyline> foundLines = [];
        if (data['elements'] != null) {
          for (var element in data['elements']) {
            if (element['type'] == 'way' && element['geometry'] != null) {
              List<LatLng> pts = [];
              for (var geom in element['geometry'])
                pts.add(LatLng(geom['lat'], geom['lon']));
              List<LatLng> simplified = _simplifyPoints(pts, threshold: 0.002);
              foundLines.add(
                Polyline(
                  points: simplified,
                  color: Colors.purpleAccent,
                  strokeWidth: 4.0,
                  borderColor: Colors.white,
                  borderStrokeWidth: 0,
                  isDotted: true,
                ),
              );
            }
          }
        }

        // 1. Lọc nhiễu
        List<Polyline> filteredLines = _filterRelevantSegments(foundLines);
        
        // 2. Cắt gọn
        List<Polyline> clippedLines = _clipPolylinesToBounds(filteredLines, searchBounds);

        setState(() => _displayedPolylines = clippedLines);
        
        if (clippedLines.isNotEmpty) {
          _fitCameraToPolylines(clippedLines);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "✅ Tìm thấy ${clippedLines.length} đoạn ranh giới (Đã lọc biển)",
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Không tìm thấy ranh giới đất liền nào!")),
          );
        }
      }
    } catch (e) {
      debugPrint("Lỗi Overpass Boundary: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi tìm kiếm: $e")),
      );
    } finally {
      setState(() => _loadingStatus = null);
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

  void _showDownloadOptionsDialog(BuildContext parentContext) {
    bool optMotorway = true;
    bool optTrunk = true;
    showDialog(
      context: parentContext,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text("Tải dữ liệu Offline (Đường bộ)"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: const [
                        Icon(Icons.info_outline, color: Colors.blue, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "Ranh giới/Biên giới chỉ tìm Online.\nSẽ tự động load từ KMZ.",
                            style: TextStyle(fontSize: 11, color: Colors.blue),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  const Text(
                    "Chọn loại đường cần tải về:",
                    style: TextStyle(fontStyle: FontStyle.italic, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    title: const Text(
                      "Đường Cao tốc",
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    value: optMotorway,
                    onChanged: (v) => setStateDialog(() => optMotorway = v!),
                  ),
                  CheckboxListTile(
                    title: const Text(
                      "Đường Quốc lộ",
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    value: optTrunk,
                    onChanged: (v) => setStateDialog(() => optTrunk = v!),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Hủy"),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text("Bắt đầu tải"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryDark,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _downloadDataInFrame(
                      dlMotorway: optMotorway,
                      dlTrunk: optTrunk,
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

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
              title: const Text("Cấu hình Khung"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildInput("Rộng (cm)", _widthCtrl)),
                      const SizedBox(width: 10),
                      Expanded(child: _buildInput("Dài (cm)", _heightCtrl)),
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
                          isSelected: [!_useOnlineSearch, _useOnlineSearch],
                          borderRadius: BorderRadius.circular(8),
                          selectedColor: Colors.white,
                          fillColor: primaryDark,
                          constraints: const BoxConstraints(
                            minWidth: 70,
                            minHeight: 32,
                          ),
                          onPressed: (index) => setStateDialog(
                            () => _useOnlineSearch = index == 1,
                          ),
                          children: const [Text("Offline"), Text("Online")],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange),
                      ),
                      child: Row(
                        children: [
                          const Text(
                            "Tìm: ",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          ChoiceChip(
                            label: const Text("Đường"),
                            selected: _searchMode == 0,
                            showCheckmark: false,
                            onSelected: (val) => setStateDialog(
                              () => _searchMode = 0,
                            ),
                          ),
                          const SizedBox(width: 4),
                          ChoiceChip(
                            label: const Text("Ranh giới"),
                            selected: _searchMode == 1,
                            selectedColor: Colors.purpleAccent,
                            showCheckmark: false,
                            // Disable khi offline vì ranh giới chỉ có online
                            onSelected: _useOnlineSearch 
                              ? (val) => setStateDialog(() => _searchMode = 1)
                              : null,
                            backgroundColor: _useOnlineSearch ? null : Colors.grey[300],
                          ),
                          const SizedBox(width: 4),
                          ChoiceChip(
                            label: const Text("Biên giới"),
                            selected: _searchMode == 2,
                            selectedColor: Colors.deepPurpleAccent,
                            showCheckmark: false,
                            // Disable khi offline vì biên giới chỉ có online
                            onSelected: _useOnlineSearch
                              ? (val) => setStateDialog(() => _searchMode = 2)
                              : null,
                            backgroundColor: _useOnlineSearch ? null : Colors.grey[300],
                          ),
                        ],
                      ),
                    ),
                    // Checkbox Lọc biển (Chỉ hiện khi chọn Biên giới hoặc Ranh giới)
                    if (_searchMode != 0)
                      CheckboxListTile(
                        title: const Text("Lọc biên giới biển"),
                        subtitle: const Text("Bỏ qua đường biên giới trên biển"),
                        value: _filterSea,
                        dense: true,
                        activeColor: primaryDark,
                        onChanged: (val) => setStateDialog(() => _filterSea = val!),
                      ),
                  if (!_useOnlineSearch) ...[
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
                          const Divider(),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.upload_file, size: 16),
                                  label: const Text(
                                    "Nạp File",
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _importData();
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.share, size: 16),
                                  label: const Text(
                                    "Xuất File",
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  onPressed: () {
                                    _exportData();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 15),
                  TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: (_searchMode == 1)
                          ? "Nhập tên Tỉnh (VD: Hà Nội)"
                          : (_searchMode == 2)
                              ? "Nhập tên Quốc gia (VD: Việt Nam)"
                              : "Nhập tên đường (VD: CT.03)...",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 15),
                  if (!_useOnlineSearch)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.cloud_download),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryDark,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showDownloadOptionsDialog(context);
                        },
                        label: const Text("Tải Dữ Liệu Khung"),
                      ),
                    ),
                  const SizedBox(height: 8),
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

  void _toggleSatellite() {
    setState(() {
      _isSatelliteMode = !_isSatelliteMode;
      if (_currentBounds != null) _generateGridOnMap(_currentBounds!);
      if (_displayedPolylines.isNotEmpty) _executeSearch();
    });
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
    Color gridColor = _isSatelliteMode ? Colors.yellowAccent : Colors.red;
    Color textColor = _isSatelliteMode ? Colors.black : Colors.red;

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
                ? Colors.green.withOpacity(0.15)
                : Colors.transparent,
            borderColor: gridColor.withOpacity(0.7),
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
                        color: Colors.white.withOpacity(0.9),
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

    String roadName = _searchCtrl.text.isEmpty
        ? "Tuyến đường"
        : _searchCtrl.text;

    // Chuyển trang và mang theo dữ liệu
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScannerPage(
          initialLimitList: sortedIds.join(", "),
          initialName: roadName,
          onSendToEsp: (cmd) {
            debugPrint("Gửi lệnh: $cmd");
          },
        ),
      ),
    );
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

  void _processKmlData(String kmlString) {
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
              color: _isSatelliteMode ? Colors.cyanAccent : Colors.black,
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
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: EdgeInsets.zero),
      );
      _saveAllSettings();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Đã tạo lưới theo KMZ!")));
      
      // [MỚI] Tự động phát hiện và load ranh giới các tỉnh trong khu vực KMZ
      _autoDetectProvincesFromKMZ(bounds);
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

  Widget _buildAppBarAction(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
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
          _buildAppBarAction(
            _isSatelliteMode ? Icons.map : Icons.satellite_alt,
            "Vệ tinh",
            _toggleSatellite,
          ),
          _buildAppBarAction(Icons.settings, "Cấu hình", _showConfigDialog),
          _buildAppBarAction(
            _cachedRoads.isEmpty ? Icons.cloud_download : Icons.search,
            "Dữ liệu",
            _showSearchDialog,
          ),
          _buildAppBarAction(Icons.file_upload, "Nạp KMZ", _pickAndFitKmz),
          _buildAppBarAction(Icons.save, "Lưu", () {
            _saveAllSettings();
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text("Đã lưu cấu hình!")));
          }),
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
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapReady: () => setState(() => _isMapReady = true),

              // [THÊM ĐOẠN NÀY] Lắng nghe sự thay đổi vị trí/zoom để cập nhật giao diện
              onPositionChanged: (position, hasGesture) {
                // Luôn render lại để check ẩn/hiện marker
                setState(() {});
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _isSatelliteMode
                    ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                tileBounds: _currentBounds,
                tileProvider: NetworkTileProvider(),
              ),
              if (_isSatelliteMode)
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

          Positioned(
            bottom: 10,
            left: 10,
            right: 10,
            child: Column(
              children: [
                // [MỚI] Nút chuyển sang Dò Bit
                if (_displayedPolylines.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: double.infinity,
                      height: 45,
                      child: ElevatedButton.icon(
                        label: const Text(
                          "CHUYỂN SANG TỰ ĐỘNG DÒ BIT",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          elevation: 5,
                        ),
                        onPressed: _transferToScanner,
                      ),
                    ),
                  ),

                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.black26, blurRadius: 5),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Khung: ${_renderWidth.toInt()}x${_renderHeight.toInt()} cm",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        "|  ${cols}x$rows Tấm",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: primaryDark,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _displayedPolylines.isEmpty
                            ? "Chưa vẽ đường"
                            : "Đã vẽ: ${_displayedPolylines.length} ${_searchMode != 0 ? 'đoạn ranh giới' : 'đoạn đường'}",
                        style: TextStyle(
                          color: _displayedPolylines.isNotEmpty
                              ? Colors.blue
                              : Colors.grey,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
      left: _showLayerPanel ? 0 : -180,
      top: 350, // Thấp hơn nữa
      bottom: 120,
      width: 180, // Thu nhỏ từ 240 xuống 180
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.97),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(10),
            bottomRight: Radius.circular(10),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
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
                  // NÚT RELOAD - Tải lại ranh giới từ KMZ
                  if (_currentBounds != null)
                    InkWell(
                      onTap: () {
                        _autoDetectProvincesFromKMZ(_currentBounds!);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Đang tải ranh giới từ KMZ..."),
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
                                        group.name,
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
                                              color: Colors.grey[400],
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
                                        Icon(
                                          isRoad ? Icons.route : Icons.description_outlined,
                                          size: 14,
                                          color: isSelected ? primaryDark : Colors.grey[500],
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
      top: 310, // Khớp với vị trí panel mới
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
              border: Border.all(color: primaryDark.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.layers, color: primaryDark, size: 18),
                SizedBox(width: 6),

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
