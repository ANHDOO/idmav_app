import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'about_page.dart';
import 'package:flutter/services.dart';
import 'bit_list_page.dart';
import 'group_bit_page.dart';
import 'scanner_page.dart';
import 'share_data_page.dart';
import 'matrix_map_page.dart';
// --- CẤU HÌNH BLE ---
const String SERVICE_UUID = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String MESSAGE_CHARACTERISTIC_UUID = '6d68efe5-04b6-4a85-abc4-c2670b7bf7fd';

// MÀU SẮC CHỦ ĐẠO
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // --- BIẾN TRẠNG THÁI ---
  List<ScanResult> scanResults = [];
  bool isScanning = false;
  BluetoothDevice? connectedDevice;
  bool isConnecting = false;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  Timer? _rssiTimer;
  final TextEditingController _textController = TextEditingController();

  int _speedIndex = 1;
  final List<String> _speedLabels = ['Chậm', 'Vừa', 'TB', 'Nhanh'];
  final List<String> _speedCommandsCompass = ['BL_100', 'BL_75', 'BL_50', 'BL_25'];
  final List<String> _speedCommandsFixed = ['DS_100', 'DS_75', 'DS_50', 'DS_25'];

  int _brightnessIndex = 1;
  final List<String> _brightnessLabels = ['Tối', 'Vừa', 'Sáng', 'Max'];
  final List<String> _brightnessCommands = ['D_1', 'D_3', 'D_6', 'D_9'];

  DateTime? _lastBackPressed;
  int _currentRssi = 0;
  bool isCompassDevice = false;
  String deviceTypeText = 'Chưa kết nối';
  StreamSubscription<List<int>>? _messageSubscription;

  final List<String> _logs = [];
  bool _logAddTime = false;
  final ScrollController _logScrollController = ScrollController();

  // --- BIẾN ĐỂ LỌC TIN NHẮN TRÙNG LẶP ---
  String? _lastProcessedRx;       // Nội dung tin nhắn RX cuối cùng
  DateTime? _lastProcessedTime;   // Thời gian nhận cuối cùng

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _rssiTimer?.cancel();
    _connectionStateSubscription?.cancel();
    super.dispose();
  }

  // --- LOGIC HỆ THỐNG ---
  Future<bool> _onWillPop() async {
    final now = DateTime.now();
    if (_lastBackPressed == null || now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nhấn lần nữa để thoát ứng dụng')));
      return false;
    }
    return true;
  }

  Future<bool> _requestBluetoothPermission() async {
    var bluetoothStatus = await Permission.bluetooth.request();
    var locationStatus = await Permission.location.request();
    if (bluetoothStatus.isGranted && locationStatus.isGranted) return true;
    return false;
  }

  void _logout(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rememberMe', false);
    Navigator.pushReplacementNamed(context, '/login');
  }

  // --- LOGIC BLE (SCAN & CONNECT) ---
  void startScan() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      if(!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vui lòng bật Bluetooth!')));
      return;
    }
    if (!await _requestBluetoothPermission()) return;

    try {
      setState(() { scanResults.clear(); isScanning = true; });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4), withKeywords: const ['ESP']);
      FlutterBluePlus.scanResults.listen((results) { if (mounted) setState(() => scanResults = results); });
    } catch (e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi: $e')));
    } finally {
      Future.delayed(const Duration(seconds: 4), () { if (mounted) setState(() => isScanning = false); });
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    // 1. Hủy listener cũ để tránh bị nhân đôi sự kiện
    await _messageSubscription?.cancel();
    _messageSubscription = null;

    if (!await _requestBluetoothPermission()) return;
    setState(() { isConnecting = true; deviceTypeText = 'Đang kết nối...'; });
    
    try {
      if (device.isConnected) {
        await device.disconnect();
      }
      
      await device.connect(autoConnect: false);
      await Future.delayed(const Duration(milliseconds: 500));
      
      var services = await device.discoverServices();
      var service = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
      var characteristic = service.characteristics.firstWhere((c) => c.uuid.toString() == MESSAGE_CHARACTERISTIC_UUID);
      await characteristic.setNotifyValue(true);
      
      // LẮNG NGHE DỮ LIỆU TỪ ESP32
      _messageSubscription = characteristic.value.listen((value) {
        if(value.isNotEmpty) {
          String response = String.fromCharCodes(value).trim();
          if (response.isEmpty) return;

          // --- BỘ LỌC CHỐNG LẶP (ANTI-DUPLICATE) ---
          final now = DateTime.now();
          // Nếu tin nhắn giống hệt tin cũ VÀ nhận trong vòng 500ms -> Bỏ qua
          if (_lastProcessedRx == response && 
              _lastProcessedTime != null && 
              now.difference(_lastProcessedTime!).inMilliseconds < 500) {
            return; 
          }

          // Cập nhật trạng thái mới nhất
          _lastProcessedRx = response;
          _lastProcessedTime = now;

          // Xử lý hiển thị
          _addLog('RX: $response');
          
          if (response == 'CD') setState(() { isCompassDevice = true; deviceTypeText = 'Sa Bàn Cơ Động'; });
          else if (response == 'Cố Định') setState(() { isCompassDevice = false; deviceTypeText = 'Sa Bàn Cố Định'; });
        }
      });

      await characteristic.write('DKN'.codeUnits);
      
      setState(() => connectedDevice = device);
      _startRssiTimer();
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() { connectedDevice = null; deviceTypeText = 'Mất kết nối'; isCompassDevice=false; });
          _rssiTimer?.cancel();
          _messageSubscription?.cancel();
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kết nối thành công!')));
    } catch (e) {
      setState(() => deviceTypeText = 'Lỗi kết nối');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi: $e')));
      _messageSubscription?.cancel();
    } finally {
      setState(() { isConnecting = false; if(connectedDevice==null) deviceTypeText='Chưa kết nối'; });
    }
  }

  void _startRssiTimer() {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (connectedDevice == null) { timer.cancel(); return; }
      try { final rssi = await connectedDevice!.readRssi(); if(mounted) setState(() => _currentRssi = rssi); } catch(e){}
    });
  }

  void disconnectDevice() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      setState(() { connectedDevice = null; deviceTypeText = 'Đã ngắt kết nối'; _logs.clear(); });
    }
  }

  Future<void> sendLedCommand(String command) async {
    if (connectedDevice != null) {
      try {
        var services = await connectedDevice!.discoverServices();
        var service = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
        var characteristic = service.characteristics.firstWhere((c) => c.uuid.toString() == MESSAGE_CHARACTERISTIC_UUID);
        
        int mtu = 450; List<int> bytes = command.codeUnits; int offset = 0;
        while (offset < bytes.length) {
          int len = (offset + mtu > bytes.length) ? bytes.length - offset : mtu;
          await characteristic.write(bytes.sublist(offset, offset + len), withoutResponse: false);
          offset += len;
        }
        // Đã bỏ dòng _addLog('TX: $command') theo ý bạn
      } catch (e) { print(e); }
    }
  }

  Future<void> sendTextCommand() async {
    if (_textController.text.isNotEmpty) {
      await sendLedCommand(_textController.text.trim());
      _textController.clear();
    }
  }

  void _addLog(String message) {
    if(!mounted) return;
    setState(() {
      String t = _logAddTime ? '[${DateTime.now().toString().split(' ')[1].split('.')[0]}] ' : '';
      _logs.add('$t$message');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if(_logScrollController.hasClients) _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
    });
  }

// --- 1. DIALOG TỐC ĐỘ (SPEED) - THIẾT KẾ MỚI ---
  void _showSpeedDialog() {
    showDialog(
      context: context,
      builder: (context) {
        int localSpeedIndex = _speedIndex;
        // Màu sắc đại diện cho từng mức độ (Chậm -> Nhanh)
        final List<Color> speedColors = [Colors.green, Colors.blue, Colors.orange, Colors.red];
        final List<IconData> speedIcons = [Icons.directions_walk, Icons.directions_run, Icons.directions_bike, Icons.rocket_launch];

        return Dialog(
          backgroundColor: Colors.transparent, // Để làm nền bo góc đẹp
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20, offset: const Offset(0, 10))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                const Text('TỐC ĐỘ NHẤP NHÁY', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 24),

                StatefulBuilder(
                  builder: (context, setStateDialog) {
                    return Column(
                      children: [
                        // VISUAL FEEDBACK (ICON ĐỘNG)
                        Container(
                          width: 80, height: 80,
                          decoration: BoxDecoration(
                            color: speedColors[localSpeedIndex].withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            speedIcons[localSpeedIndex], 
                            size: 40, 
                            color: speedColors[localSpeedIndex]
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        // TEXT HIỂN THỊ MỨC ĐỘ
                        Text(
                          _speedLabels[localSpeedIndex].toUpperCase(),
                          style: TextStyle(
                            fontSize: 24, 
                            fontWeight: FontWeight.bold, 
                            color: speedColors[localSpeedIndex]
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isCompassDevice 
                              ? 'Lệnh: ${_speedCommandsCompass[localSpeedIndex]}' 
                              : 'Lệnh: ${_speedCommandsFixed[localSpeedIndex]}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                        ),
                        
                        const SizedBox(height: 30),

                        // CUSTOM SLIDER
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: speedColors[localSpeedIndex],
                            inactiveTrackColor: Colors.grey[200],
                            trackShape: const RoundedRectSliderTrackShape(),
                            trackHeight: 12.0, // Thanh trượt dày hơn
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0),
                            thumbColor: Colors.white,
                            overlayColor: speedColors[localSpeedIndex].withOpacity(0.2),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 24.0),
                            tickMarkShape: const RoundSliderTickMarkShape(),
                            activeTickMarkColor: Colors.white.withOpacity(0.5),
                            inactiveTickMarkColor: Colors.grey[400],
                          ),
                          child: Slider(
                            value: localSpeedIndex.toDouble(),
                            min: 0, max: 3, divisions: 3,
                            onChanged: connectedDevice == null ? null : (value) async {
                              setStateDialog(() => localSpeedIndex = value.round());
                              setState(() => _speedIndex = localSpeedIndex);
                              final cmd = isCompassDevice ? _speedCommandsCompass[localSpeedIndex] : _speedCommandsFixed[localSpeedIndex];
                              await sendLedCommand(cmd);
                            },
                          ),
                        ),
                        
                        // Labels nhỏ bên dưới
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [
                              Text('Chậm', style: TextStyle(fontSize: 10, color: Colors.grey)),
                              Text('Nhanh', style: TextStyle(fontSize: 10, color: Colors.grey)),
                            ],
                          ),
                        )
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                
                // NÚT ĐÓNG
                SizedBox(
                  width: double.infinity,
                  height: 45,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[100],
                      foregroundColor: Colors.black87,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Đóng'),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  // --- 2. DIALOG ĐỘ SÁNG (BRIGHTNESS) - THIẾT KẾ MỚI ---
  void _showBrightnessDialog() {
    showDialog(
      context: context,
      builder: (context) {
        int localBrightnessIndex = _brightnessIndex;
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20, offset: const Offset(0, 10))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('ĐỘ SÁNG SA BÀN', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 24),

                StatefulBuilder(
                  builder: (context, setStateDialog) {
                    // Logic màu sắc: Tối -> Vàng nhạt -> Vàng đậm -> Cam đỏ
                    Color bulbColor = Colors.orange.withOpacity(0.3 + (localBrightnessIndex * 0.2));
                    if (localBrightnessIndex == 3) bulbColor = Colors.deepOrange;

                    return Column(
                      children: [
                        // VISUAL FEEDBACK (BÓNG ĐÈN PHÁT SÁNG)
                        Container(
                          width: 80, height: 80,
                          decoration: BoxDecoration(
                            color: bulbColor.withOpacity(0.15), // Quầng sáng nền
                            shape: BoxShape.circle,
                            boxShadow: [
                              // Hiệu ứng phát sáng (Glow effect) tăng theo mức độ
                              BoxShadow(
                                color: bulbColor.withOpacity(0.4),
                                blurRadius: (localBrightnessIndex + 1) * 10.0, // Glow to dần
                                spreadRadius: (localBrightnessIndex + 1) * 2.0,
                              )
                            ]
                          ),
                          child: Icon(
                            localBrightnessIndex == 0 ? Icons.lightbulb_outline : Icons.lightbulb, // Tắt thì dùng viền, bật dùng khối đặc
                            size: 40, 
                            color: bulbColor
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        Text(
                          _brightnessLabels[localBrightnessIndex].toUpperCase(),
                          style: TextStyle(
                            fontSize: 24, 
                            fontWeight: FontWeight.bold, 
                            color: bulbColor
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Lệnh: ${_brightnessCommands[localBrightnessIndex]}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                        ),

                        const SizedBox(height: 30),

                        // SLIDER
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: bulbColor,
                            inactiveTrackColor: Colors.grey[200],
                            trackShape: const RoundedRectSliderTrackShape(),
                            trackHeight: 12.0,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0),
                            thumbColor: Colors.white,
                            overlayColor: bulbColor.withOpacity(0.2),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 24.0),
                            tickMarkShape: const RoundSliderTickMarkShape(),
                            activeTickMarkColor: Colors.white.withOpacity(0.5),
                            inactiveTickMarkColor: Colors.grey[400],
                          ),
                          child: Slider(
                            value: localBrightnessIndex.toDouble(),
                            min: 0, max: 3, divisions: 3,
                            onChanged: connectedDevice == null ? null : (value) async {
                              setStateDialog(() => localBrightnessIndex = value.round());
                              setState(() => _brightnessIndex = localBrightnessIndex);
                              await sendLedCommand(_brightnessCommands[localBrightnessIndex]);
                            },
                          ),
                        ),
                        
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [
                              Text('Tối', style: TextStyle(fontSize: 10, color: Colors.grey)),
                              Text('Sáng chói', style: TextStyle(fontSize: 10, color: Colors.grey)),
                            ],
                          ),
                        )
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 45,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[100],
                      foregroundColor: Colors.black87,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Đóng'),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }
  // --- UI WIDGETS ---

  // 1. HEADER (Dashboard)
  Widget _buildHeaderCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 16), 
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [primaryDark, primaryLight], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: primaryDark.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(connectedDevice != null ? 'Đã kết nối' : 'Chưa kết nối', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Text(connectedDevice?.name ?? 'Sẵn sàng', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13)),
              ]),
              Icon(connectedDevice != null ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: Colors.white, size: 24),
            ],
          ),
          if (connectedDevice != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.wifi, color: Colors.greenAccent, size: 14),
                const SizedBox(width: 6),
                Text('RSSI: $_currentRssi dBm  |  $deviceTypeText', style: const TextStyle(color: Colors.white, fontSize: 12)),
              ]),
            )
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: primaryDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 10)),
              onPressed: isScanning || connectedDevice != null ? null : startScan,
              child: Text(isScanning ? 'Đang quét...' : 'Quét thiết bị'),
            )),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 10)),
              onPressed: connectedDevice == null ? null : disconnectDevice,
              child: const Text('Ngắt kết nối'),
            )),
          ])
        ],
      ),
    );
  }

  // 2. DEVICE LIST (Card ngang, Nút bên phải)
  Widget _buildDeviceList() {
    if (scanResults.isEmpty) return const SizedBox.shrink();
    return Column(
      children: scanResults.map((result) {
        bool isConnected = connectedDevice != null && connectedDevice!.id == result.device.id;
        return Container(
          margin: const EdgeInsets.only(bottom: 16), 
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isConnected ? Colors.green.withOpacity(0.5) : Colors.grey.shade200),
            boxShadow: [BoxShadow(color: Colors.grey.shade200, blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            dense: true,
            leading: CircleAvatar(
              backgroundColor: isConnected ? Colors.green.withOpacity(0.1) : const Color(0xFFE3F2FD), 
              child: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth, color: isConnected ? Colors.green : primaryDark, size: 20)
            ),
            title: Text(result.device.name.isNotEmpty ? result.device.name : 'Unknown Device', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87)),
            subtitle: Text(result.device.id.id, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: SizedBox(
              height: 32,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? Colors.grey[400] : primaryLight, 
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  elevation: 0,
                ),
                onPressed: (isConnecting || isConnected) ? null : () => connectToDevice(result.device),
                child: Text(isConnected ? 'Đã kết nối' : 'Kết nối', style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // 3. TERMINAL (Chỉ chứa Log, Không chứa Input)
  Widget _buildTerminalList() {
    return Expanded(
      child: Container(
        margin: EdgeInsets.zero,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [BoxShadow(color: Colors.grey.shade100, blurRadius: 5, offset: const Offset(0, 2))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('TERMINAL LOG', style: TextStyle(color: primaryDark, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1)),
                    Row(
                      children: [
                        SizedBox(height: 20, width: 20, child: Checkbox(value: _logAddTime, onChanged: (v) => setState(() => _logAddTime = v ?? false), activeColor: primaryDark, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)))),
                        const SizedBox(width: 4),
                        const Text('Time', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 12),
                        InkWell(onTap: () => setState(() => _logs.clear()), child: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 22)),
                      ]
                    )
                  ],
                ),
              ),
              const Divider(height: 1),
              
              Expanded(
                child: Stack(
                  children: [
                    Container(color: const Color(0xFFFAFAFA), width: double.infinity, height: double.infinity),
                    Positioned.fill(
                      child: Center(
                        child: Opacity(
                          opacity: 0.08, 
                          child: Image.asset('assets/TP.png', width: 200, fit: BoxFit.contain, errorBuilder: (c,e,s) => const Icon(Icons.business, size: 150, color: Colors.grey)),
                        ),
                      ),
                    ),
                    ListView.builder(
                      controller: _logScrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        bool isRX = _logs[index].contains('RX:');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _logs[index], 
                            style: TextStyle(
                              fontFamily: 'Courier', 
                              fontSize: 13, 
                              fontWeight: FontWeight.w500,
                              color: isRX ? Colors.green[800] : Colors.indigo[900]
                            )
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 4. FLOATING BOTTOM AREA (Chứa Input + Buttons)
  Widget _buildFloatingBottomArea(bool isKeyboardOpen) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, -2))],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A. Ô NHẬP LIỆU (Luôn hiện)
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 45,
                    decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(25), border: Border.all(color: Colors.grey.shade300)),
                    child: Row(children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          enabled: connectedDevice != null,
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(hintText: 'Nhập lệnh...', border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero),
                          onSubmitted: (_) => sendTextCommand(),
                        ),
                      ),
                      Material(color: Colors.transparent, child: InkWell(onTap: connectedDevice == null ? null : sendTextCommand, borderRadius: BorderRadius.circular(25), child: Container(padding: const EdgeInsets.all(8), margin: const EdgeInsets.only(right: 4), decoration: BoxDecoration(shape: BoxShape.circle, color: connectedDevice != null ? primaryDark : Colors.grey[300]), child: const Icon(Icons.send, color: Colors.white, size: 18)))),
                    ]),
                  ),
                ),
              ],
            ),
          ),

          // B. 3 NÚT BẤM (Ẩn khi bàn phím hiện)
          if (!isKeyboardOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  _buildCompactBtn('BẬT', Icons.power_settings_new, Colors.green, () => sendLedCommand('Full')),
                  const SizedBox(width: 10),
                  _buildCompactBtn('NHÁY', Icons.flash_on, Colors.orange, () => sendLedCommand('FB1')),
                  const SizedBox(width: 10),
                  _buildCompactBtn('TẮT', Icons.power_off, Colors.red, () => sendLedCommand('Off')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCompactBtn(String label, IconData icon, Color color, VoidCallback? onTap) {
    return Expanded(
      child: SizedBox(
        height: 40, 
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withOpacity(0.1), foregroundColor: color, elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: color.withOpacity(0.3))),
            padding: EdgeInsets.zero,
          ),
          onPressed: connectedDevice == null ? null : onTap,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 16), const SizedBox(width: 4), Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))]),
        ),
      ),
    );
  }

  // --- DRAWER ---
  Widget _buildModernDrawer() {
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: 50, bottom: 20, left: 20),
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [primaryDark, primaryLight], begin: Alignment.topLeft, end: Alignment.bottomRight)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)), child: const CircleAvatar(radius: 30, backgroundColor: Colors.white, child: Icon(Icons.person, size: 40, color: primaryDark))),
                const SizedBox(height: 12),
                const Text('iDMAV 5.0', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                const Text('Administrator', style: TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(vertical: 10), children: [
              _buildDrawerItem(Icons.settings, 'Tốc độ nhấp nháy', () {Navigator.pop(context); _showSpeedDialog();}),
              _buildDrawerItem(Icons.brightness_6, 'Độ sáng', () {Navigator.pop(context); _showBrightnessDialog();}),
              const Divider(indent: 20, endIndent: 20),
              _buildDrawerItem(Icons.list_alt, 'Danh sách Bít (Lẻ)', () {Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (ctx) => BitListPage(onSendToEsp: (d) async => connectedDevice!=null?await sendLedCommand(d):null)));}),
              _buildDrawerItem(Icons.group_work, 'Bit Tổng (Nhóm)', () {Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (ctx) => GroupBitPage(onSendToEsp: (d) async => connectedDevice!=null?await sendLedCommand(d):null)));}),
              _buildDrawerItem(Icons.radar, 'Công cụ Dò Bít', () { 
                    Navigator.pop(context); 
                    Navigator.push(
                      context, 
                      MaterialPageRoute(
                        builder: (ctx) => ScannerPage(
                          // Truyền hàm gửi lệnh xuống Scanner để nó dùng
                          onSendToEsp: (String cmd) async {
                            if (connectedDevice != null) {
                              await sendLedCommand(cmd);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Chưa kết nối Bluetooth!'))
                              );
                            }
                          }
                        )
                      )
                    );
                  }),
              _buildDrawerItem(Icons.qr_code_2, 'Chia sẻ & Đồng bộ', () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (ctx) => const ShareDataPage()));
                  }),
              _buildDrawerItem(Icons.map_outlined, 'Ma trận & Bản đồ', () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (ctx) => const MatrixMapPage()));
                  }),
            ]),
          ),
          const Divider(),
          _buildDrawerItem(Icons.info_outline, 'Thông tin phần mềm', () {Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (ctx) => const AboutPage()));}, color: Colors.grey[700]!),
          _buildDrawerItem(Icons.logout, 'Đăng xuất', () => _logout(context), color: Colors.red),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildDrawerItem(IconData icon, String title, VoidCallback onTap, {Color? color}) {
    Color itemColor = color ?? primaryDark;
    return ListTile(
      leading: Icon(icon, color: itemColor, size: 22),
      title: Text(title, style: TextStyle(color: itemColor, fontWeight: FontWeight.w500)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24), horizontalTitleGap: 10, dense: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final bool isKeyboardOpen = keyboardHeight > 0;

    return WillPopScope(
      onWillPop: () async {
        bool exit = await _onWillPop();
        if (exit) SystemNavigator.pop();
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F7FA),
        resizeToAvoidBottomInset: false, // QUAN TRỌNG
        appBar: AppBar(
          title: const Text('Bảng điều khiển', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          flexibleSpace: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [primaryDark, primaryLight]))),
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
        ),
        drawer: _buildModernDrawer(),
        body: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  _buildHeaderCard(),
                  _buildDeviceList(),
                  _buildTerminalList(),
                  SizedBox(height: isKeyboardOpen ? 60 : 120), 
                ],
              ),
            ),
            Positioned(
              left: 0, right: 0, bottom: keyboardHeight,
              child: _buildFloatingBottomArea(isKeyboardOpen),
            ),
          ],
        ),
      ),
    );
  }
}