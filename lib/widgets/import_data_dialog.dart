import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Dialog thống nhất để import/export dữ liệu tọa độ
/// Hỗ trợ: KMZ, nhập tọa độ thủ công, dán text, xuất KMZ
class ImportDataDialog extends StatefulWidget {
  final LatLngBounds? currentBounds;
  final Function(LatLngBounds bounds, List<Polyline> polylines) onBoundsCreated;
  final VoidCallback onClearBounds;
  final int initialTabIndex; // <--- Thêm tham số này

  const ImportDataDialog({
    super.key,
    this.currentBounds,
    required this.onBoundsCreated,
    required this.onClearBounds,
    this.initialTabIndex = 0, // Mặc định là tab 0
  });

  @override
  State<ImportDataDialog> createState() => _ImportDataDialogState();
}

class _ImportDataDialogState extends State<ImportDataDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Controllers
  final _northLatCtrl = TextEditingController();
  final _southLatCtrl = TextEditingController();
  final _eastLngCtrl = TextEditingController();
  final _westLngCtrl = TextEditingController();
  final _pasteTextCtrl = TextEditingController();

  bool _useDMS = true;
  String? _errorMessage;
  bool _isLoading = false;

  // Image OCR state
  File? _selectedImage;
  String? _ocrResultText;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 5, 
      vsync: this,
      initialIndex: widget.initialTabIndex, // <--- Sử dụng ở đây
    );
    
    if (widget.currentBounds != null) {
      _northLatCtrl.text = widget.currentBounds!.north.toStringAsFixed(6);
      _southLatCtrl.text = widget.currentBounds!.south.toStringAsFixed(6);
      _eastLngCtrl.text = widget.currentBounds!.east.toStringAsFixed(6);
      _westLngCtrl.text = widget.currentBounds!.west.toStringAsFixed(6);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _northLatCtrl.dispose();
    _southLatCtrl.dispose();
    _eastLngCtrl.dispose();
    _westLngCtrl.dispose();
    _pasteTextCtrl.dispose();
    super.dispose();
  }

  /// Parse DMS format: "21° 47' 0" N" → 21.7833
  double? _parseDMS(String input) {
    try {
      // Tiền xử lý: Thay thế 'O'/'o' nhầm bằng '0', chuẩn hóa các ký tự đặc biệt
      input = input.trim().toUpperCase()
          .replaceAll(RegExp(r'[O\u03BF\u03BF]'), '0') // Thay chữ O thành số 0
          .replaceAll('′', "'")
          .replaceAll('″', '"')
          .replaceAll('’', "'")
          .replaceAll('”', '"');
      
      // Decimal simple
      double? simple = double.tryParse(input.replaceAll(RegExp(r'[NSEW]'), '').trim());
      if (simple != null && !input.contains('°')) {
        bool isNegative = input.contains('S') || input.contains('W');
        return isNegative ? -simple : simple;
      }
      
      // Parse DMS - dùng regex linh hoạt hơn cho nhiều định dạng
      // Matches: 21° 47' 0" N, 21-47-0 N, 21.47.0 N, etc.
      RegExp regex = RegExp(r"(\d+)\s*[°\-\s\.]\s*(\d+)?\s*['\.\s\-]?\s*(\d+\.?\d*)?\s*[" + '"' + r"\s\-]?\s*([NSEW])?");
      Match? match = regex.firstMatch(input);
      if (match == null) return null;
      
      double degrees = double.parse(match.group(1) ?? '0');
      double minutes = double.parse(match.group(2) ?? '0');
      double seconds = double.parse(match.group(3) ?? '0');
      String? direction = match.group(4);
      
      double decimal = degrees + (minutes / 60) + (seconds / 3600);
      
      if (direction == 'S' || direction == 'W') {
        decimal = -decimal;
      }
      
      return decimal;
    } catch (e) {
      return null;
    }
  }

  Future<void> _pickKmzFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['kmz', 'kml'],
      );

      if (result != null && result.files.single.path != null) {
        String path = result.files.single.path!;
        String kmlString;

        if (path.toLowerCase().endsWith('.kmz')) {
          final bytes = File(path).readAsBytesSync();
          final archive = ZipDecoder().decodeBytes(bytes);
          final kmlFile = archive.files.firstWhere(
            (f) => f.name.endsWith('.kml'),
            orElse: () => throw Exception('Không tìm thấy file KML trong KMZ'),
          );
          kmlString = String.fromCharCodes(kmlFile.content as List<int>);
        } else {
          kmlString = File(path).readAsStringSync();
        }

        _processKmlString(kmlString);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Lỗi: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _processKmlString(String kmlString) {
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
            double lng = double.parse(parts[0]);
            double lat = double.parse(parts[1]);
            segmentPoints.add(LatLng(lat, lng));
            allPoints.add(LatLng(lat, lng));
          }
        }
        
        if (segmentPoints.isNotEmpty) {
          lines.add(Polyline(
            points: segmentPoints,
            color: Colors.black,
            strokeWidth: 2,
            isDotted: true,
          ));
        }
      }

      if (allPoints.isEmpty) {
        setState(() => _errorMessage = 'Không tìm thấy tọa độ trong file');
        return;
      }

      double minLat = allPoints.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
      double maxLat = allPoints.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
      double minLon = allPoints.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
      double maxLon = allPoints.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

      LatLngBounds bounds = LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));

      widget.onBoundsCreated(bounds, lines);
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ Đã import KMZ thành công!')),
      );
    } catch (e) {
      setState(() => _errorMessage = 'Lỗi parse KML: $e');
    }
  }

  void _applyManualCoordinates() {
    setState(() => _errorMessage = null);

    double? north = _useDMS ? _parseDMS(_northLatCtrl.text) : double.tryParse(_northLatCtrl.text);
    double? south = _useDMS ? _parseDMS(_southLatCtrl.text) : double.tryParse(_southLatCtrl.text);
    double? east = _useDMS ? _parseDMS(_eastLngCtrl.text) : double.tryParse(_eastLngCtrl.text);
    double? west = _useDMS ? _parseDMS(_westLngCtrl.text) : double.tryParse(_westLngCtrl.text);

    if (north == null || south == null || east == null || west == null) {
      setState(() => _errorMessage = 'Vui lòng nhập đủ 4 tọa độ hợp lệ');
      return;
    }

    if (north <= south) {
      setState(() => _errorMessage = 'Vĩ độ Bắc phải lớn hơn Vĩ độ Nam');
      return;
    }

    if (east <= west) {
      setState(() => _errorMessage = 'Kinh độ Đông phải lớn hơn Kinh độ Tây');
      return;
    }

    LatLngBounds bounds = LatLngBounds(LatLng(south, west), LatLng(north, east));

    List<Polyline> lines = [
      Polyline(
        points: [
          LatLng(south, west),
          LatLng(south, east),
          LatLng(north, east),
          LatLng(north, west),
          LatLng(south, west),
        ],
        color: Colors.black,
        strokeWidth: 2,
        isDotted: true,
      ),
    ];

    widget.onBoundsCreated(bounds, lines);
    Navigator.of(context).pop();
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✓ Đã tạo khung từ tọa độ!')),
    );
  }

  /// Phân tích text để tìm tọa độ
  void _parseTextForCoordinates() {
    setState(() => _errorMessage = null);

    String text = _pasteTextCtrl.text;
    if (text.isEmpty) {
      setState(() => _errorMessage = 'Vui lòng dán text chứa tọa độ');
      return;
    }
    
    double? north, south, east, west;

    // Tìm tất cả ứng cử viên tọa độ (DMS hoặc Decimal cao độ)
    RegExp dmsCandidate = RegExp(r"(\d+)\s*[°\-\s\.]\s*(\d+)?\s*['\.\s\-]?\s*(\d+\.?\d*)?\s*[" + '"' + r"\s\-]?\s*([NSEW])?");
    RegExp decimalCandidate = RegExp(r"(\d{1,2}\.\d{4,})|(\d{3}\.\d{4,})");
    
    List<double> latitudes = [];
    List<double> longitudes = [];
    
    // Ưu tiên DMS trước
    for (Match m in dmsCandidate.allMatches(text)) {
      String fullMatch = m.group(0) ?? '';
      if (fullMatch.length < 5) continue; // Tránh các số đơn lẻ vô nghĩa
      
      double? val = _parseDMS(fullMatch);
      if (val != null) {
        String dir = m.group(4) ?? '';
        // Một số OCR gộp chung kinh vĩ vào 1 dòng, ta thử tách ra
        if (dir == 'N' || dir == 'S' || (val > 0 && val < 50)) {
          latitudes.add(val);
        } else if (dir == 'E' || dir == 'W' || val >= 80) {
          longitudes.add(val);
        }
      }
    }
    
    // Nếu chưa đủ, tìm thêm Decimal (>= 4 chữ số thập phân cho chính xác)
    if (latitudes.length < 2 || longitudes.length < 2) {
      for (Match m in decimalCandidate.allMatches(text)) {
        double? val = double.tryParse(m.group(0) ?? '');
        if (val != null) {
          if (val > 0 && val < 50 && !latitudes.contains(val)) {
            latitudes.add(val);
          } else if (val >= 80 && val < 180 && !longitudes.contains(val)) {
            longitudes.add(val);
          }
        }
      }
    }
    
    if (latitudes.length >= 2 && longitudes.length >= 2) {
      latitudes.sort();
      longitudes.sort();
      south = latitudes.first;
      north = latitudes.last;
      west = longitudes.first;
      east = longitudes.last;
    }

    if (north != null && south != null && east != null && west != null) {
      _northLatCtrl.text = north.toStringAsFixed(6);
      _southLatCtrl.text = south.toStringAsFixed(6);
      _eastLngCtrl.text = east.toStringAsFixed(6);
      _westLngCtrl.text = west.toStringAsFixed(6);
      
      setState(() => _useDMS = false);
      _tabController.animateTo(1);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ Đã phân tích tọa độ! Kiểm tra và nhấn Tạo khung')),
      );
    } else {
      setState(() {
        _errorMessage = 'Không tìm thấy đủ 4 tọa độ.\n'
            'Ví dụ format:\n'
            'Vĩ độ: 15° 50\' 0" N ÷ 21° 47\' 0" N\n'
            'Kinh độ: 105° 29\' 23" E ÷ 110° 40\' 18" E';
      });
    }
  }

  Future<void> _exportToKmz() async {
    if (widget.currentBounds == null) {
      setState(() => _errorMessage = 'Chưa có khung tọa độ để xuất');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final bounds = widget.currentBounds!;
      
      String kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Exported Bounds</name>
    <Placemark>
      <name>Grid Bounds</name>
      <LineString>
        <coordinates>
          ${bounds.west},${bounds.south},0
          ${bounds.east},${bounds.south},0
          ${bounds.east},${bounds.north},0
          ${bounds.west},${bounds.north},0
          ${bounds.west},${bounds.south},0
        </coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>''';

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final kmzPath = '${directory.path}/export_$timestamp.kmz';
      
      final archive = Archive();
      archive.addFile(ArchiveFile('doc.kml', kml.length, kml.codeUnits));
      final kmzBytes = ZipEncoder().encode(archive);
      await File(kmzPath).writeAsBytes(kmzBytes!);

      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✓ Đã xuất: $kmzPath')),
      );
    } catch (e) {
      setState(() => _errorMessage = 'Lỗi xuất KMZ: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        height: 500,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.input, color: Colors.indigo),
                const SizedBox(width: 8),
                const Text('Import / Export Dữ liệu',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),

            // Tabs - căn đều 5 chức năng
            TabBar(
              controller: _tabController,
              labelColor: Colors.indigo,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.indigo,
              isScrollable: false, // Tắt scrollable để chia đều
              labelPadding: const EdgeInsets.symmetric(horizontal: 4), // Thu gọn padding
              tabs: const [
                Tab(icon: Icon(Icons.folder_zip, size: 16), text: 'KMZ'),
                Tab(icon: Icon(Icons.edit_location, size: 16), text: 'Tọa độ'),
                Tab(icon: Icon(Icons.content_paste, size: 16), text: 'Dán'),
                Tab(icon: Icon(Icons.image, size: 16), text: 'Ảnh'),
                Tab(icon: Icon(Icons.save_alt, size: 16), text: 'Xuất'),
              ],
            ),
            const SizedBox(height: 12),

            // Tab Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildKmzTab(),
                  _buildCoordinatesTab(),
                  _buildPasteTextTab(),
                  _buildImageTab(),
                  _buildExportTab(),
                ],
              ),
            ),

            // Error message
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_errorMessage!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  ],
                ),
              ),

            if (_isLoading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildKmzTab() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.folder_zip, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Text('Import từ file KMZ hoặc KML'),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _isLoading ? null : _pickKmzFile,
          icon: const Icon(Icons.file_open),
          label: const Text('Chọn file .kmz / .kml'),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: widget.currentBounds != null
              ? () {
                  widget.onClearBounds();
                  Navigator.of(context).pop();
                }
              : null,
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          label: const Text('Xóa khung hiện tại', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }

  Widget _buildCoordinatesTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Định dạng: '),
              ChoiceChip(
                label: const Text('DMS'),
                selected: _useDMS,
                onSelected: (v) => setState(() => _useDMS = true),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Decimal'),
                selected: !_useDMS,
                onSelected: (v) => setState(() => _useDMS = false),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _northLatCtrl,
            decoration: InputDecoration(
              labelText: 'Vĩ độ Bắc (N)',
              hintText: _useDMS ? '21° 47\' 0"' : '21.7833',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _southLatCtrl,
            decoration: InputDecoration(
              labelText: 'Vĩ độ Nam (S)',
              hintText: _useDMS ? '15° 50\' 0"' : '15.8333',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _eastLngCtrl,
            decoration: InputDecoration(
              labelText: 'Kinh độ Đông (E)',
              hintText: _useDMS ? '110° 40\' 18"' : '110.6717',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _westLngCtrl,
            decoration: InputDecoration(
              labelText: 'Kinh độ Tây (W)',
              hintText: _useDMS ? '105° 29\' 23"' : '105.4897',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _applyManualCoordinates,
              icon: const Icon(Icons.check),
              label: const Text('Tạo khung từ tọa độ'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasteTextTab() {
    return Column(
      children: [
        const Text('Dán text chứa tọa độ để phân tích',
            style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            controller: _pasteTextCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: 'Ví dụ:\nVĩ độ: 15° 50\' 0" N ÷ 21° 47\' 0" N\n'
                  'Kinh độ: 105° 29\' 23" E ÷ 110° 40\' 18" E',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(4),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _parseTextForCoordinates,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Phân tích'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => _pasteTextCtrl.clear(),
              icon: const Icon(Icons.clear),
              tooltip: 'Xóa text',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildImageTab() {
    // Check platform support
    bool isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    
    if (isDesktop) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.desktop_windows, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'OCR chỉ hỗ trợ trên Android/iOS\n\nVui lòng sử dụng tab "Dán" để nhập text thủ công',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _tabController.animateTo(2), // Go to Paste tab
            icon: const Icon(Icons.content_paste),
            label: const Text('Chuyển sang tab Dán'),
          ),
        ],
      );
    }
    
    return SingleChildScrollView(
      child: Column(
        children: [
          // Image preview
          Container(
            height: 150,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[400]!),
            ),
            child: _selectedImage != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(_selectedImage!, fit: BoxFit.cover),
                  )
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.image_search, size: 48, color: Colors.grey),
                      SizedBox(height: 8),
                      Text('Chưa chọn ảnh', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          
          // Pick image buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library, size: 18),
                  label: const Text('Thư viện'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt, size: 18),
                  label: const Text('Chụp ảnh'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // OCR button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _selectedImage == null || _isLoading ? null : _runOcr,
              icon: const Icon(Icons.document_scanner),
              label: Text(_isLoading ? 'Đang quét...' : 'Quét văn bản (OCR)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          
          // OCR Result
          if (_ocrResultText != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.text_fields, size: 16, color: Colors.blue),
                      const SizedBox(width: 4),
                      const Text('Kết quả OCR:', 
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      const Spacer(),
                      InkWell(
                        onTap: () => setState(() => _ocrResultText = null),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _ocrResultText!,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  _pasteTextCtrl.text = _ocrResultText!;
                  _parseTextForCoordinates();
                },
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Phân tích tọa độ'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      
      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
          _ocrResultText = null;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() => _errorMessage = 'Lỗi chọn ảnh: $e');
    }
  }

  Future<void> _runOcr() async {
    if (_selectedImage == null) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final inputImage = InputImage.fromFile(_selectedImage!);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      await textRecognizer.close();
      
      if (recognizedText.text.isEmpty) {
        setState(() => _errorMessage = 'Không tìm thấy văn bản trong ảnh');
      } else {
        // [TỐI ƯU] Lọc chỉ lấy các dòng có khả năng là tọa độ
        // Bao gồm: Có dấu độ °, có hướng N,S,E,W, hoặc có nhiều dấu thập phân
        final List<String> filteredLines = [];
        final coordPattern = RegExp(r"[°NSEW']|\d{1,3}\.\d{4,}", caseSensitive: false);
        
        for (TextBlock block in recognizedText.blocks) {
          for (TextLine line in block.lines) {
            if (coordPattern.hasMatch(line.text)) {
              filteredLines.add(line.text.trim());
            }
          }
        }
        
        String result = filteredLines.join('\n');
        
        if (result.isEmpty) {
          setState(() => _errorMessage = 'Không nhận diện được tọa độ nào trong ảnh. Hãy thử ảnh rõ nét hơn.');
          setState(() => _ocrResultText = recognizedText.text); // Vẫn hiện text gốc để debug
        } else {
          setState(() => _ocrResultText = result);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✓ Đã lọc xong tọa độ! Nhấn "Phân tích tọa độ" để tiếp tục')),
          );
        }
      }
    } catch (e) {
      setState(() => _errorMessage = 'Lỗi OCR: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }


  Widget _buildExportTab() {
    final hasBounds = widget.currentBounds != null;
    
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (hasBounds) ...[
          const Icon(Icons.check_circle, size: 48, color: Colors.green),
          const SizedBox(height: 12),
          const Text('Khung hiện tại:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Text('Bắc: ${widget.currentBounds!.north.toStringAsFixed(4)}°'),
                Text('Nam: ${widget.currentBounds!.south.toStringAsFixed(4)}°'),
                Text('Đông: ${widget.currentBounds!.east.toStringAsFixed(4)}°'),
                Text('Tây: ${widget.currentBounds!.west.toStringAsFixed(4)}°'),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _isLoading ? null : _exportToKmz,
            icon: const Icon(Icons.save_alt),
            label: const Text('Xuất ra file KMZ'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ] else ...[
          const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
          const SizedBox(height: 12),
          const Text('Chưa có khung tọa độ nào'),
          const Text('Hãy import KMZ hoặc nhập tọa độ trước',
              style: TextStyle(color: Colors.grey)),
        ],
      ],
    );
  }
}
