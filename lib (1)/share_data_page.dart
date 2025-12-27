import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

// Màu chủ đạo
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

class ShareDataPage extends StatefulWidget {
  const ShareDataPage({Key? key}) : super(key: key);

  @override
  State<ShareDataPage> createState() => _ShareDataPageState();
}

class _ShareDataPageState extends State<ShareDataPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final MobileScannerController _cameraController = MobileScannerController();
  
  String _qrData = ""; 
  bool _isGenerating = true;
  bool _isTooLongForQr = false; // Biến kiểm tra độ dài
  int _dataLength = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _prepareData();
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // --- 1. CHUẨN BỊ DỮ LIỆU ---
  Future<void> _prepareData() async {
    final prefs = await SharedPreferences.getInstance();
    String bitsData = prefs.getString('saved_bits_data') ?? "[]";
    String groupsData = prefs.getString('saved_groups_data') ?? "[]";

    // Đóng gói JSON (Minify để giảm ký tự)
    Map<String, dynamic> package = {
      "b": jsonDecode(bitsData), // Dùng key ngắn 'b' thay vì 'bits' để tiết kiệm QR
      "g": jsonDecode(groupsData), // 'g' thay vì 'groups'
      "v": "1.0"
    };

    String rawJson = jsonEncode(package);
    
    setState(() {
      _qrData = rawJson;
      _dataLength = rawJson.length;
      // Giới hạn an toàn cho QR Code trên điện thoại là khoảng 2000-2500 ký tự
      _isTooLongForQr = _dataLength > 2500; 
      _isGenerating = false;
    });
  }

  // --- 2. GỬI BẰNG FILE (BACKUP) ---
  Future<void> _shareAsFile() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/idmav_data.json');
      await file.writeAsString(_qrData); // Ghi dữ liệu hiện tại ra file

      await Share.shareXFiles(
        [XFile(file.path)], 
        text: 'File cấu hình iDMAV ($_dataLength bytes)'
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Lỗi chia sẻ file: $e")));
    }
  }

  // --- 3. XỬ LÝ NHẬN DỮ LIỆU (CHUNG CHO CẢ QR VÀ FILE) ---
  Future<void> _processImport(String jsonString) async {
    try {
      Map<String, dynamic> data = jsonDecode(jsonString);
      
      // Hỗ trợ cả key cũ (bits) và key rút gọn (b)
      var bits = data['bits'] ?? data['b'];
      var groups = data['groups'] ?? data['g'];

      if (bits != null && groups != null) {
        _showConfirmDialog(bits, groups);
      } else {
        throw Exception("Dữ liệu không hợp lệ");
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Dữ liệu lỗi hoặc sai định dạng!")));
      // Nếu đang quét camera thì bật lại
      _cameraController.start();
    }
  }

  // Chọn file từ máy
  Future<void> _pickFileToImport() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );

      if (result != null) {
        File file = File(result.files.single.path!);
        String content = await file.readAsString();
        _processImport(content);
      }
    } catch (e) {}
  }

  // Xử lý quét QR
  void _onQrDetect(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue != null) {
        _cameraController.stop(); // Dừng camera ngay khi bắt được
        _processImport(barcode.rawValue!);
        break;
      }
    }
  }

  Future<void> _showConfirmDialog(List bits, List groups) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [Icon(Icons.check_circle, color: Colors.green), SizedBox(width: 10), Text("Dữ liệu hợp lệ!")]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("• ${bits.length} Bít lẻ"),
            Text("• ${groups.length} Nhóm"),
            const SizedBox(height: 10),
            const Text("Bạn có muốn GHI ĐÈ dữ liệu này vào máy không?", style: TextStyle(color: Colors.red)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cameraController.start(); // Bật lại camera nếu hủy
            }, 
            child: const Text("Hủy")
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              Navigator.pop(ctx);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('saved_bits_data', jsonEncode(bits));
              await prefs.setString('saved_groups_data', jsonEncode(groups));
              if(!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Đã nhập dữ liệu thành công!")));
              Navigator.pop(context); // Thoát trang share
            },
            child: const Text("Đồng ý", style: TextStyle(color: Colors.white)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Chia sẻ & Đồng bộ", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [primaryDark, primaryLight]))),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.upload), text: "Gửi (QR / File)"),
            Tab(icon: Icon(Icons.download), text: "Nhận (Scan / File)"),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // --- TAB 1: GỬI ---
          Center(
            child: _isGenerating 
              ? const CircularProgressIndicator()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // LOGIC HIỂN THỊ QR: Chỉ hiện nếu dữ liệu nhỏ
                      if (!_isTooLongForQr) ...[
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
                          child: QrImageView(
                            data: _qrData,
                            version: QrVersions.auto,
                            size: 260.0,
                            backgroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text("Quét mã này để lấy dữ liệu ($_dataLength chars)", style: const TextStyle(color: Colors.green, fontSize: 12)),
                      ] else ...[
                        // [ĐÃ SỬA LỖI] Thay Icons.qr_code_off bằng Icons.broken_image
                        const Icon(Icons.broken_image, size: 80, color: Colors.grey),
                        const SizedBox(height: 10),
                        const Text("Dữ liệu quá lớn để tạo QR!", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
                        Text("Kích thước: $_dataLength ký tự (Max QR ~2500)", style: const TextStyle(color: Colors.grey)),
                        const SizedBox(height: 10),
                        const Text("Vui lòng sử dụng tính năng Gửi File bên dưới.", textAlign: TextAlign.center),
                      ],

                      const SizedBox(height: 30),
                      const Divider(),
                      const SizedBox(height: 20),

                      // NÚT GỬI FILE (LUÔN HIỆN ĐỂ DỰ PHÒNG)
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: primaryDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                          icon: const Icon(Icons.share, color: Colors.white),
                          label: const Text("CHIA SẺ BẰNG FILE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          onPressed: _shareAsFile,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text("Khuyên dùng nếu dữ liệu nhiều hoặc ở xa.", style: TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
                    ],
                  ),
                ),
          ),

          // --- TAB 2: NHẬN ---
          Stack(
            alignment: Alignment.center,
            children: [
              MobileScanner(
                controller: _cameraController,
                onDetect: _onQrDetect,
              ),
              
              // Khung trang trí
              Container(
                decoration: BoxDecoration(border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 2), borderRadius: BorderRadius.circular(20)),
                width: 280, height: 280,
              ),
              const Positioned(top: 100, child: Text("Quét mã QR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 4, color: Colors.black)]))),

              // NÚT NHẬP FILE (Nổi bên dưới)
              Positioned(
                bottom: 40,
                left: 40, right: 40,
                child: Column(
                  children: [
                    const Text("Hoặc nếu bạn có file sao lưu:", style: TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4, color: Colors.black)])),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: primaryDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                        icon: const Icon(Icons.folder_open),
                        label: const Text("CHỌN FILE DỮ LIỆU", style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: _pickFileToImport,
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
        ],
      ),
    );
  }
}