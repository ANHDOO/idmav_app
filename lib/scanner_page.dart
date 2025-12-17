import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- MÀU SẮC CHỦ ĐẠO ---
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

// --- MODEL CHI TIẾT BÍT (ĐỂ LƯU DANH SÁCH) ---
class BitDetail {
  int stt;
  String tam; // Mã tấm (Hex)
  int cong;   // Số cổng (1-16)

  BitDetail({required this.stt, required this.tam, required this.cong});

  Map<String, dynamic> toJson() => {'stt': stt, 'tam': tam, 'cong': cong};

  factory BitDetail.fromJson(Map<String, dynamic> json) {
    return BitDetail(stt: json['stt'], tam: json['tam'], cong: json['cong']);
  }
}

class ScannerPage extends StatefulWidget {
  final Function(String) onSendToEsp;
  
  // [QUAN TRỌNG] Tham số nhận từ MatrixMapPage
  final String? initialLimitList; // Danh sách ID (VD: "26, 27")
  final String? initialName;      // Tên đường (VD: "QL1A")
  
  /// Callback để quay lại Map (nếu có)
  final VoidCallback? onBackToMap;

  const ScannerPage({
    Key? key, 
    required this.onSendToEsp,
    this.initialLimitList, 
    this.initialName,
    this.onBackToMap,
  }) : super(key: key);

  @override
  State<ScannerPage> createState() => ScannerPageState();
}

/// State public để MainNavigation có thể gọi setInitialData() khi navigate từ Map
class ScannerPageState extends State<ScannerPage> {
  // Controllers
  final TextEditingController _panelController = TextEditingController(text: "01");
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _limitListController = TextEditingController();
  
  // State variables
  bool _isLimitMode = false;
  int _selectedPort = -1; 
  bool _isAutoScanning = false;
  Timer? _scanTimer;
  double _scanSpeedMs = 800; 
  
  // Danh sách các điểm đã chọn để lưu
  List<BitDetail> _pendingDetails = [];

  @override
  void initState() {
    super.initState();
    _selectedPort = 0; // Mặc định chọn ô số 1
    _loadSavedSettings();

    // [LOGIC NHẬN DỮ LIỆU TỪ MAP]
    if (widget.initialLimitList != null && widget.initialLimitList!.isNotEmpty) {
      _limitListController.text = widget.initialLimitList!;
      _isLimitMode = true; // Tự động bật chế độ giới hạn
      
      // Tự động set tấm đầu tiên trong danh sách
      List<String> limits = _parseLimitList();
      if (limits.isNotEmpty) {
        _panelController.text = limits[0];
      }
    }

    if (widget.initialName != null) {
      _nameController.text = widget.initialName!;
    }
  }

  /// PUBLIC: Được gọi từ MainNavigation khi navigate từ Map với tên và danh sách tấm
  void setInitialData({String? name, String? limitList}) {
    setState(() {
      if (name != null && name.isNotEmpty) {
        _nameController.text = name;
      }
      if (limitList != null && limitList.isNotEmpty) {
        _limitListController.text = limitList;
        _isLimitMode = true;
        List<String> limits = _parseLimitList();
        if (limits.isNotEmpty) {
          _panelController.text = limits[0];
        }
      }
      // Clear pending data khi có data mới từ Map
      _pendingDetails.clear();
      _selectedPort = 0;
    });
  }

  Future<void> _loadSavedSettings() async {
    // Chỉ load settings cũ nếu KHÔNG có dữ liệu mới truyền sang
    if (widget.initialLimitList == null) {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _scanSpeedMs = prefs.getDouble('scan_speed') ?? 800;
        // Đảm bảo giá trị trong khoảng cho phép (500-2000)
        if (_scanSpeedMs < 500) _scanSpeedMs = 500;
        if (_scanSpeedMs > 2000) _scanSpeedMs = 2000;
        _limitListController.text = prefs.getString('scan_limit_list') ?? "";
        _isLimitMode = prefs.getBool('scan_limit_mode') ?? false;
      });
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('scan_speed', _scanSpeedMs);
    await prefs.setString('scan_limit_list', _limitListController.text);
    await prefs.setBool('scan_limit_mode', _isLimitMode);
  }

  // --- LOGIC GỬI LỆNH ---
  String _makeCommand(String panelHex, int portIndex, bool turnOn) {
    try {
      int panelVal = int.parse(panelHex, radix: 16);
      int portVal = portIndex; 
      // Quy ước: Bật = Port + 16, Tắt = Port
      int finalPortVal = turnOn ? (portVal + 16) : portVal;
      
      String p = panelVal.toRadixString(16).toUpperCase().padLeft(2, '0');
      String c = finalPortVal.toRadixString(16).toUpperCase().padLeft(2, '0');
      return "$p$c";
    } catch (e) { return ""; }
  }

  void _testPort(int portIndex) {
    if (_panelController.text.isEmpty) return;
    
    // Tắt đèn cũ nếu đang sáng
    if (_selectedPort != -1 && _selectedPort != portIndex) {
       widget.onSendToEsp(_makeCommand(_panelController.text, _selectedPort, false));
    }
    
    setState(() { _selectedPort = portIndex; });
    // Bật đèn mới
    widget.onSendToEsp(_makeCommand(_panelController.text, portIndex, true));
  }

  void _turnOffCurrent() {
    if (_selectedPort != -1) {
      widget.onSendToEsp(_makeCommand(_panelController.text, _selectedPort, false));
      setState(() { _selectedPort = -1; });
    }
  }

  // --- LOGIC AUTO SCAN ---
  void _toggleAutoScan() {
    if (_isAutoScanning) _stopScan();
    else _startScan();
  }

  void _startScan() {
    setState(() => _isAutoScanning = true);
    
    if (_isLimitMode) {
      List<String> limits = _parseLimitList();
      if (limits.isEmpty) {
        _stopScan();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Danh sách giới hạn trống!')));
        return;
      }
      // Nếu tấm hiện tại không có trong list -> Nhảy về tấm đầu tiên
      if (!limits.contains(_panelController.text.toUpperCase())) {
        _panelController.text = limits[0];
      }
    }

    int currentIdx = _selectedPort == -1 ? 0 : _selectedPort; 
    _testPort(currentIdx); // Bật ngay lập tức

    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(Duration(milliseconds: _scanSpeedMs.toInt()), (timer) {
      currentIdx++;
      
      // Hết 16 cổng -> Chuyển tấm
      if (currentIdx > 15) {
        currentIdx = 0; 
        bool canContinue = _autoNextPanel(); 
        if (!canContinue) return; 
      }

      _testPort(currentIdx);
    });
  }

  List<String> _parseLimitList() {
    String text = _limitListController.text.replaceAll(' ', ''); 
    if (text.isEmpty) return [];
    List<String> rawList = text.split(',');
    List<String> validList = [];
    for (var item in rawList) {
      if (item.isNotEmpty) {
        try {
          int val = int.parse(item, radix: 16);
          if (val >= 0 && val <= 255) {
             validList.add(val.toRadixString(16).toUpperCase().padLeft(2, '0'));
          }
        } catch (e) {}
      }
    }
    return validList;
  }

  bool _autoNextPanel() {
    String currentHex = _panelController.text.toUpperCase();
    
    if (_isLimitMode) {
      List<String> limits = _parseLimitList();
      int currentIndex = limits.indexOf(currentHex);
      
      if (currentIndex == -1 || currentIndex >= limits.length - 1) {
        _stopScan();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã quét xong danh sách!')));
        return false;
      } 
      setState(() => _panelController.text = limits[currentIndex + 1]);
      return true;

    } else {
      try {
        int currentVal = int.parse(currentHex, radix: 16);
        if (currentVal >= 99) {
          _stopScan();
          return false;
        }
        int nextVal = currentVal + 1;
        setState(() {
          _panelController.text = nextVal.toRadixString(16).toUpperCase().padLeft(2, '0');
        });
        return true;
      } catch (e) {
        _stopScan();
        return false;
      }
    }
  }

  void _stopScan() {
    _scanTimer?.cancel();
    _turnOffCurrent();
    setState(() => _isAutoScanning = false);
  }

  // --- QUẢN LÝ DANH SÁCH & LƯU ---
  void _addToPending() {
    if (_panelController.text.isEmpty || _selectedPort == -1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chưa có đèn nào đang sáng!')));
      return;
    }
    String tam = _panelController.text.padLeft(2, '0').toUpperCase();
    int congHienThi = _selectedPort + 1; 
    
    bool exists = _pendingDetails.any((d) => d.tam == tam && d.cong == congHienThi);
    if (exists) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Điểm này đã có trong danh sách!')));
      return;
    }
    setState(() {
      _pendingDetails.insert(0, BitDetail(stt: 0, tam: tam, cong: congHienThi));
      for (int i = 0; i < _pendingDetails.length; i++) {
        _pendingDetails[i].stt = _pendingDetails.length - i;
      }
    });
  }

  void _removeFromPending(int index) {
    setState(() {
      _pendingDetails.removeAt(index);
      for (int i = 0; i < _pendingDetails.length; i++) {
        _pendingDetails[i].stt = _pendingDetails.length - i;
      }
    });
  }

  Future<void> _saveFinalButton() async {
    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vui lòng nhập tên nút!')));
      return;
    }
    if (_pendingDetails.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Danh sách chi tiết đang trống!')));
      return;
    }
    try {
      StringBuffer rawDataBuffer = StringBuffer();
      // Đảo ngược lại để lưu đúng thứ tự thao tác (cũ nhất -> mới nhất)
      List<BitDetail> orderedDetails = _pendingDetails.reversed.toList();
      for(int i=0; i<orderedDetails.length; i++) orderedDetails[i].stt = i + 1;

      for (var detail in orderedDetails) {
        rawDataBuffer.write(detail.tam);
        int rawPort = detail.cong - 1;
        rawDataBuffer.write(rawPort.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }

      final prefs = await SharedPreferences.getInstance();
      String? encodedData = prefs.getString('saved_bits_data');
      List<dynamic> jsonList = encodedData != null ? jsonDecode(encodedData) : [];
      
      int newId = jsonList.length + 1;
      Map<String, dynamic> newItem = {
        'id': newId.toString(), 
        'name': _nameController.text, 
        'rawData': rawDataBuffer.toString(), 
        'isEnabled': false, 
        'details': orderedDetails.map((e) => e.toJson()).toList()
      };
      
      jsonList.add(newItem);
      await prefs.setString('saved_bits_data', jsonEncode(jsonList));
      
      setState(() { 
        _nameController.clear(); 
        _pendingDetails.clear(); 
        _selectedPort = 0; 
      });
      _turnOffCurrent();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã lưu thành công!')));
    } catch (e) { 
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi lưu: $e'))); 
    }
  }

  void _changePanel(int value) {
    String currentHex = _panelController.text.toUpperCase();
    if (_isLimitMode) {
      List<String> limits = _parseLimitList();
      if (limits.isEmpty) return;
      int idx = limits.indexOf(currentHex);
      if (idx == -1) idx = 0;
      else idx += value;
      
      if (idx >= limits.length) idx = 0;
      if (idx < 0) idx = limits.length - 1;
      
      setState(() => _panelController.text = limits[idx]);
    } else {
      try {
        int current = int.parse(currentHex, radix: 16);
        int next = current + value;
        if (next < 1) next = 1; 
        if (next > 99) next = 99; 
        setState(() => _panelController.text = next.toRadixString(16).toUpperCase().padLeft(2, '0'));
      } catch (e) {}
    }
    _turnOffCurrent();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _turnOffCurrent();
    _saveSettings();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Công cụ Dò Bít', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        centerTitle: true,
        flexibleSpace: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [primaryDark, primaryLight]))),
        iconTheme: const IconThemeData(color: Colors.white),
        automaticallyImplyLeading: false,
        // Chỉ hiển thị nút Back khi navigate từ Map (onBackToMap != null)
        leading: widget.onBackToMap != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: widget.onBackToMap,
              )
            : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. CẤU HÌNH QUÉT
            Card(
              elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Text('MÃ TẤM (HEX): ', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                        IconButton(onPressed: () => _changePanel(-1), icon: const Icon(Icons.remove_circle, color: Colors.blue)),
                        SizedBox(width: 60, child: TextField(controller: _panelController, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: primaryDark), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4), border: InputBorder.none), onChanged: (v) => _turnOffCurrent())),
                        IconButton(onPressed: () => _changePanel(1), icon: const Icon(Icons.add_circle, color: Colors.blue)),
                    ]),
                    const Divider(),
                    Row(
                      children: [
                        Checkbox(value: _isLimitMode, activeColor: Colors.purple, onChanged: (val) { setState(() => _isLimitMode = val ?? false); _saveSettings(); }),
                        const Expanded(child: Text('Chỉ quét theo danh sách:', style: TextStyle(fontWeight: FontWeight.w500))),
                      ],
                    ),
                    if (_isLimitMode)
                      Padding(
                        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                        child: TextField(controller: _limitListController, decoration: const InputDecoration(hintText: 'VD: 26, 27...', isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)), onChanged: (v) => _saveSettings()),
                      ),
                    const Divider(),
                    Row(children: [
                        const Icon(Icons.speed, color: Colors.orange), const SizedBox(width: 8),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Tốc độ: ${_scanSpeedMs.toInt()} ms', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              Slider(
                                value: _scanSpeedMs, 
                                min: 500, 
                                max: 2000, 
                                divisions: 15, 
                                activeColor: Colors.orange, 
                                onChanged: (v) { 
                                  setState(() => _scanSpeedMs = v); 
                                  _saveSettings(); 
                                }
                              ),
                        ])),
                    ])
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // 2. MA TRẬN & AUTO SCAN
            Container(
              padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade300)),
              child: Column(children: [
                  GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8, crossAxisSpacing: 6, mainAxisSpacing: 6), itemCount: 16, itemBuilder: (context, index) {
                      bool isActive = _selectedPort == index;
                      return GestureDetector(onTap: () { if (_isAutoScanning) _stopScan(); isActive ? _turnOffCurrent() : _testPort(index); }, child: Container(decoration: BoxDecoration(color: isActive ? Colors.green : Colors.grey[100], borderRadius: BorderRadius.circular(8), border: Border.all(color: isActive ? Colors.green : Colors.grey.shade400), boxShadow: isActive ? [const BoxShadow(color: Colors.greenAccent, blurRadius: 6)] : null), child: Center(child: Text('${index + 1}', style: TextStyle(color: isActive ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)))));
                  }),
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, height: 45, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: _isAutoScanning ? Colors.red : primaryDark), icon: Icon(_isAutoScanning ? Icons.stop : Icons.play_arrow, color: Colors.white), label: Text(_isAutoScanning ? 'DỪNG' : 'CHẠY TỰ ĐỘNG', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), onPressed: _toggleAutoScan)),
              ]),
            ),
            const SizedBox(height: 16),

            // 3. KHU VỰC THÊM VÀO LIST
            Container(
              padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.blue.withOpacity(0.3))),
              child: Row(children: [
                  const Icon(Icons.wb_incandescent, color: Colors.orange), const SizedBox(width: 8),
                  Expanded(child: Text(_selectedPort != -1 ? 'Đang chọn: ${_panelController.text} - ${_selectedPort + 1}' : 'Chọn cổng để thêm...', style: TextStyle(fontWeight: FontWeight.bold, color: _selectedPort != -1 ? Colors.blue[900] : Colors.grey))),
                  ElevatedButton(onPressed: _selectedPort != -1 ? _addToPending : null, style: ElevatedButton.styleFrom(backgroundColor: Colors.blue), child: const Text('Thêm', style: TextStyle(color: Colors.white)))
              ]),
            ),
            const SizedBox(height: 16),

            // 4. DANH SÁCH & LƯU
            const Text('DANH SÁCH CHI TIẾT', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 8),
            Container(
              height: 150, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade300)),
              child: _pendingDetails.isEmpty ? const Center(child: Text('Chưa có điểm nào được thêm', style: TextStyle(color: Colors.grey))) : ListView.separated(padding: const EdgeInsets.all(8), itemCount: _pendingDetails.length, separatorBuilder: (ctx, i) => const Divider(height: 1), itemBuilder: (ctx, index) { final detail = _pendingDetails[index]; return ListTile(dense: true, leading: CircleAvatar(backgroundColor: index == 0 ? Colors.green[100] : Colors.blue[100], radius: 14, child: Text('${detail.stt}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: index==0 ? Colors.green[800] : Colors.blue[800]))), title: Text('Tấm: ${detail.tam}  |  Cổng: ${detail.cong}', style: TextStyle(fontWeight: FontWeight.bold, color: index == 0 ? Colors.green[800] : Colors.black87)), trailing: IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.red), onPressed: () => _removeFromPending(index))); }),
            ),
            const SizedBox(height: 16),
            TextField(controller: _nameController, decoration: InputDecoration(labelText: 'Tên Nút Nhấn Mới', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), prefixIcon: const Icon(Icons.edit))),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, height: 50, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.green, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 5), icon: const Icon(Icons.save, color: Colors.white), label: Text('LƯU DỮ LIỆU', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), onPressed: _pendingDetails.isNotEmpty ? _saveFinalButton : null)),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}