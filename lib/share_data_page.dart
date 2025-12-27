import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

// Màu chủ đạo
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

// Model cho Project
class ProjectData {
  final String name;
  final String fileName;
  final DateTime createdAt;
  final int bitsCount;
  final int groupsCount;

  ProjectData({
    required this.name,
    required this.fileName,
    required this.createdAt,
    required this.bitsCount,
    required this.groupsCount,
  });

  factory ProjectData.fromJson(Map<String, dynamic> json, String fileName) {
    List bits = json['data']?['bits'] ?? json['bits'] ?? [];
    List groups = json['data']?['groups'] ?? json['groups'] ?? [];
    return ProjectData(
      name: json['projectName'] ?? 'Không tên',
      fileName: fileName,
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      bitsCount: bits.length,
      groupsCount: groups.length,
    );
  }
}

class ShareDataPage extends StatefulWidget {
  const ShareDataPage({Key? key}) : super(key: key);

  @override
  State<ShareDataPage> createState() => _ShareDataPageState();
}

class _ShareDataPageState extends State<ShareDataPage> {
  List<ProjectData> _projects = [];
  bool _isLoading = true;
  
  // Thống kê dữ liệu hiện tại
  int _currentBitsCount = 0;
  int _currentGroupsCount = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // --- LOAD DỮ LIỆU ---
  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    // Load thống kê hiện tại
    final prefs = await SharedPreferences.getInstance();
    String bitsData = prefs.getString('saved_bits_data') ?? "[]";
    String groupsData = prefs.getString('saved_groups_data') ?? "[]";
    List bits = jsonDecode(bitsData);
    List groups = jsonDecode(groupsData);
    
    // Load danh sách dự án đã lưu
    List<ProjectData> projects = await _loadProjects();
    
    setState(() {
      _currentBitsCount = bits.length;
      _currentGroupsCount = groups.length;
      _projects = projects;
      _isLoading = false;
    });
  }

  // Lấy thư mục lưu trữ projects
  Future<Directory> _getProjectsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final projectsDir = Directory('${appDir.path}/idmav_projects');
    if (!await projectsDir.exists()) {
      await projectsDir.create(recursive: true);
    }
    return projectsDir;
  }

  // Load danh sách projects từ thư mục
  Future<List<ProjectData>> _loadProjects() async {
    try {
      final dir = await _getProjectsDir();
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
      
      List<ProjectData> projects = [];
      for (var file in files) {
        try {
          String content = await file.readAsString();
          Map<String, dynamic> json = jsonDecode(content);
          String fileName = file.path.split(Platform.pathSeparator).last;
          projects.add(ProjectData.fromJson(json, fileName));
        } catch (e) {
          // Skip invalid files
        }
      }
      
      // Sắp xếp theo ngày tạo mới nhất
      projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return projects;
    } catch (e) {
      return [];
    }
  }

  // --- THU THẬP TOÀN BỘ DỮ LIỆU TỪ APP ---
  Future<Map<String, dynamic>> _collectAllData(String projectName) async {
    final prefs = await SharedPreferences.getInstance();
    
    return {
      "projectName": projectName,
      "createdAt": DateTime.now().toIso8601String(),
      "version": "1.0",
      "data": {
        // Bits & Groups
        "bits": jsonDecode(prefs.getString('saved_bits_data') ?? "[]"),
        "groups": jsonDecode(prefs.getString('saved_groups_data') ?? "[]"),
        
        // Map Config
        "mapConfig": {
          "width": prefs.getString('map_width') ?? "600",
          "height": prefs.getString('map_height') ?? "700",
          "tileSize": prefs.getInt('map_tile_size') ?? 50,
          "satelliteMode": prefs.getBool('map_satellite_mode') ?? false,
          "tileIds": prefs.getString('map_tile_ids') ?? "{}",
          "centerLat": prefs.getDouble('map_center_lat') ?? 21.0285,
          "centerLng": prefs.getDouble('map_center_lng') ?? 105.8542,
          "zoom": prefs.getDouble('map_zoom') ?? 10.0,
        },
        
        // KMZ Bounds
        "bounds": {
          "minLat": prefs.getDouble('kmz_min_lat'),
          "maxLat": prefs.getDouble('kmz_max_lat'),
          "minLng": prefs.getDouble('kmz_min_lng'),
          "maxLng": prefs.getDouble('kmz_max_lng'),
        },
        
        // Scanner Config
        "scannerConfig": {
          "speed": prefs.getDouble('scan_speed') ?? 800,
          "limitList": prefs.getString('scan_limit_list') ?? "",
          "limitMode": prefs.getBool('scan_limit_mode') ?? false,
        },
      },
    };
  }

  // --- LƯU DỰ ÁN MỚI ---
  Future<void> _saveNewProject(String projectName) async {
    try {
      final data = await _collectAllData(projectName);
      final dir = await _getProjectsDir();
      
      // Tạo filename an toàn
      String safeName = projectName.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      String fileName = '${safeName}_$timestamp.json';
      
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(jsonEncode(data));
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✓ Đã lưu dự án '$projectName'"),
          backgroundColor: Colors.green,
        ),
      );
      
      await _loadData(); // Refresh list
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi lưu dự án: $e")),
      );
    }
  }

  // --- KHÔI PHỤC DỰ ÁN ---
  Future<void> _restoreProject(ProjectData project) async {
    try {
      final dir = await _getProjectsDir();
      final file = File('${dir.path}/${project.fileName}');
      String content = await file.readAsString();
      Map<String, dynamic> json = jsonDecode(content);
      
      final prefs = await SharedPreferences.getInstance();
      final data = json['data'] ?? json;
      
      // Khôi phục Bits & Groups
      if (data['bits'] != null) {
        await prefs.setString('saved_bits_data', jsonEncode(data['bits']));
      }
      if (data['groups'] != null) {
        await prefs.setString('saved_groups_data', jsonEncode(data['groups']));
      }
      
      // Khôi phục Map Config
      final mapConfig = data['mapConfig'];
      if (mapConfig != null) {
        await prefs.setString('map_width', mapConfig['width'] ?? "600");
        await prefs.setString('map_height', mapConfig['height'] ?? "700");
        await prefs.setInt('map_tile_size', mapConfig['tileSize'] ?? 50);
        await prefs.setBool('map_satellite_mode', mapConfig['satelliteMode'] ?? false);
        if (mapConfig['tileIds'] != null) {
          await prefs.setString('map_tile_ids', 
            mapConfig['tileIds'] is String ? mapConfig['tileIds'] : jsonEncode(mapConfig['tileIds']));
        }
        await prefs.setDouble('map_center_lat', (mapConfig['centerLat'] ?? 21.0285).toDouble());
        await prefs.setDouble('map_center_lng', (mapConfig['centerLng'] ?? 105.8542).toDouble());
        await prefs.setDouble('map_zoom', (mapConfig['zoom'] ?? 10.0).toDouble());
      }
      
      // Khôi phục Bounds
      final bounds = data['bounds'];
      if (bounds != null) {
        if (bounds['minLat'] != null) await prefs.setDouble('kmz_min_lat', bounds['minLat'].toDouble());
        if (bounds['maxLat'] != null) await prefs.setDouble('kmz_max_lat', bounds['maxLat'].toDouble());
        if (bounds['minLng'] != null) await prefs.setDouble('kmz_min_lng', bounds['minLng'].toDouble());
        if (bounds['maxLng'] != null) await prefs.setDouble('kmz_max_lng', bounds['maxLng'].toDouble());
      }
      
      // Khôi phục Scanner Config
      final scannerConfig = data['scannerConfig'];
      if (scannerConfig != null) {
        await prefs.setDouble('scan_speed', (scannerConfig['speed'] ?? 800).toDouble());
        await prefs.setString('scan_limit_list', scannerConfig['limitList'] ?? "");
        await prefs.setBool('scan_limit_mode', scannerConfig['limitMode'] ?? false);
      }
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✓ Đã khôi phục dự án! Vui lòng khởi động lại app."),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
      
      await _loadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi khôi phục: $e")),
      );
    }
  }

  // --- XÓA DỰ ÁN ---
  Future<void> _deleteProject(ProjectData project) async {
    try {
      final dir = await _getProjectsDir();
      final file = File('${dir.path}/${project.fileName}');
      if (await file.exists()) {
        await file.delete();
      }
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Đã xóa '${project.name}'")),
      );
      
      await _loadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi xóa dự án: $e")),
      );
    }
  }

  // --- CHIA SẺ DỰ ÁN ---
  Future<void> _shareProject(ProjectData project) async {
    try {
      final dir = await _getProjectsDir();
      final file = File('${dir.path}/${project.fileName}');
      
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Dự án iDMAV: ${project.name}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi chia sẻ: $e")),
      );
    }
  }

  // --- NHẬP FILE TỪ BÊN NGOÀI ---
  Future<void> _importFromFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );

      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        String content = await file.readAsString();
        Map<String, dynamic> json = jsonDecode(content);
        
        // Kiểm tra định dạng
        String projectName = json['projectName'] ?? 'Imported Project';
        
        // Copy file vào thư mục projects
        final dir = await _getProjectsDir();
        String safeName = projectName.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_');
        String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
        String fileName = '${safeName}_$timestamp.json';
        
        final newFile = File('${dir.path}/$fileName');
        await newFile.writeAsString(content);
        
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("✓ Đã nhập dự án '$projectName'"),
            backgroundColor: Colors.green,
          ),
        );
        
        await _loadData();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi nhập file: $e")),
      );
    }
  }

  // --- DIALOG TẠO DỰ ÁN MỚI ---
  void _showCreateProjectDialog() {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.create_new_folder, color: primaryDark),
            SizedBox(width: 10),
            Text("Lưu Dự án mới"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Toàn bộ cấu hình hiện tại sẽ được lưu:",
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMiniStat("$_currentBitsCount", "Bít"),
                  _buildMiniStat("$_currentGroupsCount", "Nhóm"),
                  _buildMiniStat("•", "Map"),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: "Tên dự án",
                hintText: "VD: Tác chiến điện tử 87-2025",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.folder),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Hủy"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: primaryDark),
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx);
                _saveNewProject(controller.text.trim());
              }
            },
            child: const Text("Lưu", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // --- DIALOG XÁC NHẬN KHÔI PHỤC ---
  void _showRestoreDialog(ProjectData project) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.restore, color: Colors.orange),
            SizedBox(width: 10),
            Text("Khôi phục Dự án"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              project.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              "${project.bitsCount} bít • ${project.groupsCount} nhóm",
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Dữ liệu hiện tại sẽ bị ghi đè!",
                      style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () {
              Navigator.pop(ctx);
              _restoreProject(project);
            },
            child: const Text("Khôi phục", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Lưu trữ & Chia sẻ",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [primaryDark, primaryLight]),
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'Nhập từ file',
            onPressed: _importFromFile,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateProjectDialog,
        backgroundColor: primaryDark,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Lưu dự án", style: TextStyle(color: Colors.white)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _projects.length,
                  itemBuilder: (ctx, index) => _buildProjectCard(_projects[index]),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_open, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            "Chưa có dự án nào",
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            "Nhấn nút 'Lưu dự án' để bắt đầu",
            style: TextStyle(color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectCard(ProjectData project) {
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm');
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      child: InkWell(
        onTap: () => _showRestoreDialog(project),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Icon
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: primaryLight.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.folder, color: primaryDark, size: 28),
              ),
              const SizedBox(width: 16),
              
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _buildChip("${project.bitsCount} bít", Colors.blue),
                        const SizedBox(width: 6),
                        _buildChip("${project.groupsCount} nhóm", Colors.green),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      dateFormat.format(project.createdAt),
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              
              // Actions
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Colors.grey[600]),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onSelected: (value) {
                  switch (value) {
                    case 'restore':
                      _showRestoreDialog(project);
                      break;
                    case 'share':
                      _shareProject(project);
                      break;
                    case 'delete':
                      _showDeleteConfirmDialog(project);
                      break;
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.restore, color: Colors.orange),
                        SizedBox(width: 8),
                        Text('Khôi phục'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'share',
                    child: Row(
                      children: [
                        Icon(Icons.share, color: Colors.blue),
                        SizedBox(width: 8),
                        Text('Chia sẻ'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Xóa', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteConfirmDialog(ProjectData project) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Xóa dự án?"),
        content: Text("Bạn có chắc muốn xóa '${project.name}'?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Hủy"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteProject(project);
            },
            child: const Text("Xóa", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildMiniStat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ],
    );
  }
}