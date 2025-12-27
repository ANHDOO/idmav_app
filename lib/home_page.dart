import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:app_settings/app_settings.dart';
import 'dart:async';
import 'dart:io'; // Cần thiết để kiểm tra Platform.isAndroid
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

// Import các page khác của bạn (Giữ nguyên)
import 'about_page.dart';
import 'bit_list_page.dart';
import 'group_bit_page.dart';
import 'scanner_page.dart';
import 'share_data_page.dart';
import 'matrix_map_page.dart';
import 'services/update_service.dart';

// --- CẤU HÌNH BLE ---
const String SERVICE_UUID = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String MESSAGE_CHARACTERISTIC_UUID = '6d68efe5-04b6-4a85-abc4-c2670b7bf7fd';

// MÀU SẮC CHỦ ĐẠO
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

class HomePage extends StatefulWidget {
  final void Function(bool isConnected)? onConnectionChanged;

  const HomePage({Key? key, this.onConnectionChanged}) : super(key: key);

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
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
  String? _lastProcessedRx;
  DateTime? _lastProcessedTime;

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

  // --- CẤP QUYỀN (ĐÃ TỐI ƯU HÓA CHO ANDROID 12+) ---
  Future<bool> _requestBluetoothPermission() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      // 1. Kiểm tra xem đã có quyền chưa trước khi hỏi
      bool scanStatus = await Permission.bluetoothScan.isGranted;
      bool connectStatus = await Permission.bluetoothConnect.isGranted;
      bool locationStatus = await Permission.location.isGranted;

      // Nếu đã có đủ quyền Bluetooth (Android 12+) hoặc Location (Android cũ) thì trả về luôn
      if (sdkInt >= 31) {
        if (scanStatus && connectStatus) return true;
      } else {
        if (locationStatus) return true;
      }

      // 2. Nếu chưa có, mới gom lại hỏi
      List<Permission> permissions = [];
      if (sdkInt >= 31) {
        permissions.add(Permission.bluetoothScan);
        permissions.add(Permission.bluetoothConnect);
      } else {
        permissions.add(Permission.location);
      }

      if (permissions.isEmpty) return true;

      Map<Permission, PermissionStatus> statuses = await permissions.request();
      
      if (sdkInt >= 31) {
        return (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
               (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
      } else {
        return statuses[Permission.location]?.isGranted ?? false;
      }
    } else {
      // iOS
      if (await Permission.bluetooth.isGranted) return true;
      return (await Permission.bluetooth.request()).isGranted;
    }
  }

  void _logout(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rememberMe', false);
    Navigator.pushReplacementNamed(context, '/login');
  }

  // --- DIALOG BẬT BLUETOOTH (ĐÃ SỬA LỖI RACE CONDITION) ---
  void _showBluetoothOffDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.bluetooth_disabled, color: Colors.red, size: 28),
            SizedBox(width: 10),
            Text('Bluetooth đang tắt'),
          ],
        ),
        content: const Text(
          'Vui lòng bật Bluetooth và cấp quyền để ứng dụng hoạt động.',
          style: TextStyle(fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Để sau'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryLight,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.pop(context); // Đóng dialog trước

              // 1. Xin quyền trước
              bool hasPerm = await _requestBluetoothPermission();
              if (!hasPerm) {
                 AppSettings.openAppSettings();
                 return;
              }

              // 2. Bật Bluetooth và ĐỢI (không dùng delay)
              try {
                if (Platform.isAndroid) {
                  await FlutterBluePlus.turnOn();
                  // Chờ đến khi adapter thực sự ON
                  await FlutterBluePlus.adapterState
                      .where((s) => s == BluetoothAdapterState.on)
                      .first;
                  
                  // 3. Sau khi ON thì tự quét
                  if (mounted) startScan();
                } else {
                  AppSettings.openAppSettings(type: AppSettingsType.bluetooth);
                }
              } catch (e) {
                AppSettings.openAppSettings(type: AppSettingsType.bluetooth);
              }
            },
            icon: const Icon(Icons.bluetooth, size: 18),
            label: const Text('Bật & Quét'),
          ),
        ],
      ),
    );
  }

  // --- LOGIC BLE (SCAN & CONNECT) ---
  void startScan() async {
    // Kiểm tra trạng thái Adapter
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      if (!mounted) return;
      _showBluetoothOffDialog();
      return;
    }

    // Kiểm tra quyền lần cuối
    if (!await _requestBluetoothPermission()) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thiếu quyền truy cập (Vị trí/Bluetooth)')));
       return;
    }

    try {
      setState(() { scanResults.clear(); isScanning = true; });
      
      // Bắt đầu quét - Tối ưu cho Android 12+
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = Platform.isAndroid ? await deviceInfo.androidInfo : null;
      final sdkInt = androidInfo?.version.sdkInt ?? 0;

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 5), 
        withKeywords: const ['ESP'], // Chỉ quét thiết bị có tên chứa ESP
        androidUsesFineLocation: sdkInt < 31, // Android 12+ không cần Location cho BLE
      );
      
      FlutterBluePlus.scanResults.listen((results) {
        if (mounted) setState(() => scanResults = results);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi quét: $e')));
    } finally {
      // Tự tắt trạng thái loading sau timeout
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) setState(() => isScanning = false);
      });
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    await _messageSubscription?.cancel();
    _messageSubscription = null;

    // Xin quyền lại cho chắc chắn (Android 12+ cần quyền Connect riêng)
    if (!await _requestBluetoothPermission()) return;

    setState(() { isConnecting = true; deviceTypeText = 'Đang kết nối...'; });

    try {
      // Nếu đang nối thì ngắt trước
      if (device.isConnected) {
        await device.disconnect();
      }

      await device.connect(autoConnect: false, mtu: null); // mtu null để auto negotiate
      await Future.delayed(const Duration(milliseconds: 500)); // Ổn định kết nối
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
          await Future.delayed(const Duration(milliseconds: 500)); 
        } catch (e) {
          print("Không xin được MTU: $e");
        }
      }
      var services = await device.discoverServices();
      var service = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
      var characteristic = service.characteristics.firstWhere((c) => c.uuid.toString() == MESSAGE_CHARACTERISTIC_UUID);
      
      await characteristic.setNotifyValue(true);

      // LẮNG NGHE DỮ LIỆU
      _messageSubscription = characteristic.value.listen((value) {
        if (value.isNotEmpty) {
          String response = String.fromCharCodes(value).trim();
          if (response.isEmpty) return;

          // --- BỘ LỌC CHỐNG LẶP (Debounce) ---
          final now = DateTime.now();
          if (_lastProcessedRx == response &&
              _lastProcessedTime != null &&
              now.difference(_lastProcessedTime!).inMilliseconds < 500) {
            return;
          }

          _lastProcessedRx = response;
          _lastProcessedTime = now;

          _addLog('RX: $response');

          if (response == 'CD') setState(() { isCompassDevice = true; deviceTypeText = 'Sa Bàn Cơ Động'; });
          else if (response == 'Cố Định') setState(() { isCompassDevice = false; deviceTypeText = 'Sa Bàn Cố Định'; });
        }
      });

      // Gửi lệnh check thiết bị
      await characteristic.write('DKN'.codeUnits);

      setState(() => connectedDevice = device);
      widget.onConnectionChanged?.call(true);
      _startRssiTimer();

      // Lắng nghe trạng thái kết nối (để xử lý khi mất kết nối bất ngờ)
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() { connectedDevice = null; deviceTypeText = 'Mất kết nối'; isCompassDevice = false; });
          widget.onConnectionChanged?.call(false);
          _rssiTimer?.cancel();
          _messageSubscription?.cancel();
        }
      });
    } catch (e) {
      setState(() => deviceTypeText = 'Lỗi kết nối');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi: $e')));
      _messageSubscription?.cancel();
    } finally {
      setState(() { isConnecting = false; if (connectedDevice == null) deviceTypeText = 'Chưa kết nối'; });
    }
  }

  void _startRssiTimer() {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (connectedDevice == null) { timer.cancel(); return; }
      try { final rssi = await connectedDevice!.readRssi(); if (mounted) setState(() => _currentRssi = rssi); } catch (e) {}
    });
  }

  void disconnectDevice() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      setState(() { connectedDevice = null; deviceTypeText = 'Đã ngắt kết nối'; _logs.clear(); });
      widget.onConnectionChanged?.call(false);
    }
  }

  Future<void> sendLedCommand(String command) async {
    if (connectedDevice != null) {
      try {
        var services = await connectedDevice!.discoverServices();
        var service = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);
        var characteristic = service.characteristics.firstWhere((c) => c.uuid.toString() == MESSAGE_CHARACTERISTIC_UUID);

        // Chia nhỏ gói tin nếu quá dài (MTU splitting)
        int mtu = 512; // An toàn cho BLE thông thường
        List<int> bytes = command.codeUnits;
        int offset = 0;
        while (offset < bytes.length) {
          int len = (offset + mtu > bytes.length) ? bytes.length - offset : mtu;
          await characteristic.write(bytes.sublist(offset, offset + len), withoutResponse: false);
          offset += len;
        }
      } catch (e) {
        _addLog('Error TX: $e');
      }
    }
  }

  Future<void> sendTextCommand() async {
    FocusScope.of(context).unfocus();
    if (_textController.text.isNotEmpty) {
      await sendLedCommand(_textController.text.trim());
      _textController.clear();
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      String t = _logAddTime ? '[${DateTime.now().toString().split(' ')[1].split('.')[0]}] ' : '';
      _logs.add('$t$message');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
    });
  }

  // --- UI DIALOGS (Giữ nguyên thiết kế đẹp của bạn) ---
  void _showSpeedDialog() {
    showDialog(
      context: context,
      builder: (context) {
        int localSpeedIndex = _speedIndex;
        final List<Color> speedColors = [Colors.green, Colors.blue, Colors.orange, Colors.red];
        final List<IconData> speedIcons = [Icons.directions_walk, Icons.directions_run, Icons.directions_bike, Icons.rocket_launch];

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
                const Text('TỐC ĐỘ NHẤP NHÁY', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 24),
                StateBuilder(
                  builder: (context, setStateDialog) {
                    return Column(
                      children: [
                        Container(
                          width: 80, height: 80,
                          decoration: BoxDecoration(color: speedColors[localSpeedIndex].withOpacity(0.1), shape: BoxShape.circle),
                          child: Icon(speedIcons[localSpeedIndex], size: 40, color: speedColors[localSpeedIndex]),
                        ),
                        const SizedBox(height: 16),
                        Text(_speedLabels[localSpeedIndex].toUpperCase(), style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: speedColors[localSpeedIndex])),
                        const SizedBox(height: 8),
                        Text(isCompassDevice ? 'Lệnh: ${_speedCommandsCompass[localSpeedIndex]}' : 'Lệnh: ${_speedCommandsFixed[localSpeedIndex]}', style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
                        const SizedBox(height: 30),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: speedColors[localSpeedIndex],
                            inactiveTrackColor: Colors.grey[200],
                            trackShape: const RoundedRectSliderTrackShape(), trackHeight: 12.0,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0), thumbColor: Colors.white,
                            overlayColor: speedColors[localSpeedIndex].withOpacity(0.2),
                          ),
                          child: Slider(
                            value: localSpeedIndex.toDouble(), min: 0, max: 3, divisions: 3,
                            onChanged: connectedDevice == null ? null : (value) async {
                              setStateDialog(() => localSpeedIndex = value.round());
                              setState(() => _speedIndex = localSpeedIndex);
                              final cmd = isCompassDevice ? _speedCommandsCompass[localSpeedIndex] : _speedCommandsFixed[localSpeedIndex];
                              await sendLedCommand(cmd);
                            },
                          ),
                        ),
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: const [Text('Chậm', style: TextStyle(fontSize: 10, color: Colors.grey)), Text('Nhanh', style: TextStyle(fontSize: 10, color: Colors.grey))])),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(width: double.infinity, height: 45, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[100], foregroundColor: Colors.black87, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), onPressed: () => Navigator.pop(context), child: const Text('Đóng'))),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showBrightnessDialog() {
    showDialog(
      context: context,
      builder: (context) {
        int localBrightnessIndex = _brightnessIndex;
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20, offset: const Offset(0, 10))]),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('ĐỘ SÁNG SA BÀN', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                const SizedBox(height: 24),
                StateBuilder(
                  builder: (context, setStateDialog) {
                    Color bulbColor = Colors.orange.withOpacity(0.3 + (localBrightnessIndex * 0.2));
                    if (localBrightnessIndex == 3) bulbColor = Colors.deepOrange;
                    return Column(
                      children: [
                        Container(
                          width: 80, height: 80,
                          decoration: BoxDecoration(color: bulbColor.withOpacity(0.15), shape: BoxShape.circle, boxShadow: [BoxShadow(color: bulbColor.withOpacity(0.4), blurRadius: (localBrightnessIndex + 1) * 10.0, spreadRadius: (localBrightnessIndex + 1) * 2.0)]),
                          child: Icon(localBrightnessIndex == 0 ? Icons.lightbulb_outline : Icons.lightbulb, size: 40, color: bulbColor),
                        ),
                        const SizedBox(height: 16),
                        Text(_brightnessLabels[localBrightnessIndex].toUpperCase(), style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: bulbColor)),
                        const SizedBox(height: 8),
                        Text('Lệnh: ${_brightnessCommands[localBrightnessIndex]}', style: const TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic)),
                        const SizedBox(height: 30),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(activeTrackColor: bulbColor, inactiveTrackColor: Colors.grey[200], trackHeight: 12.0, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0), thumbColor: Colors.white, overlayColor: bulbColor.withOpacity(0.2)),
                          child: Slider(
                            value: localBrightnessIndex.toDouble(), min: 0, max: 3, divisions: 3,
                            onChanged: connectedDevice == null ? null : (value) async {
                              setStateDialog(() => localBrightnessIndex = value.round());
                              setState(() => _brightnessIndex = localBrightnessIndex);
                              await sendLedCommand(_brightnessCommands[localBrightnessIndex]);
                            },
                          ),
                        ),
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: const [Text('Tối', style: TextStyle(fontSize: 10, color: Colors.grey)), Text('Sáng chói', style: TextStyle(fontSize: 10, color: Colors.grey))])),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(width: double.infinity, height: 45, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[100], foregroundColor: Colors.black87, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), onPressed: () => Navigator.pop(context), child: const Text('Đóng'))),
              ],
            ),
          ),
        );
      },
    );
  }

Widget _buildHeaderCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [primaryDark, primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: primaryDark.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 5),
          )
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connectedDevice != null ? 'Đã kết nối' : 'Chưa kết nối',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    connectedDevice?.name ?? 'Sẵn sàng',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.8),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              Icon(
                connectedDevice != null
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color: Colors.white,
                size: 24,
              ),
            ],
          ),
          if (connectedDevice != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi, color: Colors.greenAccent, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'RSSI: $_currentRssi dBm  |  $deviceTypeText',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            )
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white, // Màu nền khi active
                    foregroundColor: primaryDark, // Màu chữ khi active
                    // --- KHẮC PHỤC LỖI MỜ NÚT ---
                    disabledBackgroundColor: Colors.white.withOpacity(0.3), // Màu nền khi disable (trắng mờ)
                    disabledForegroundColor: Colors.white.withOpacity(0.6), // Màu chữ khi disable (trắng đục)
                    // -----------------------------
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  // Logic: Nếu đang quét HOẶC đã kết nối rồi thì disable nút này
                  onPressed: isScanning || connectedDevice != null
                      ? null
                      : startScan,
                  child: Text(isScanning ? 'Đang quét...' : 'Quét thiết bị'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: connectedDevice == null ? null : disconnectDevice,
                  child: const Text('Ngắt kết nối'),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

Widget _buildDeviceList() {
    // --- THÊM DÒNG NÀY ĐỂ ẨN DANH SÁCH KHI ĐÃ KẾT NỐI ---
    // Khi return SizedBox.shrink(), widget Terminal bên dưới sẽ tự động tràn lên
    if (connectedDevice != null) return const SizedBox.shrink();
    // -----------------------------------------------------

    if (scanResults.isEmpty) {
      // [v1.1.6] Hiển thị thông báo khi đã quét xong nhưng không có thiết bị
      if (!isScanning) {
        return Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.shade200),
          ),
          child: Row(
            children: [
              Icon(Icons.bluetooth_searching, color: Colors.orange[700], size: 24),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Không tìm thấy thiết bị ESP',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('Đảm bảo thiết bị đã bật và gần điện thoại',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        );
      }
      return const SizedBox.shrink();
    }
    
    // Phần hiển thị danh sách giữ nguyên, nhưng bọc trong Flexible để không bị lỗi layout nếu danh sách quá dài
    return Container(
      // Giới hạn chiều cao tối đa của list để không đẩy Terminal xuống quá sâu nếu quét ra quá nhiều thiết bị
      constraints: const BoxConstraints(maxHeight: 200), 
      child: ListView(
        shrinkWrap: true, // Quan trọng: Chỉ chiếm diện tích vừa đủ nội dung
        padding: EdgeInsets.zero,
        children: scanResults.map((result) {
          bool isConnected = connectedDevice != null &&
              connectedDevice!.id == result.device.id;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: isConnected
                      ? Colors.green.withOpacity(0.5)
                      : Colors.grey.shade200),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.shade200,
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                )
              ],
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
              dense: true,
              leading: CircleAvatar(
                backgroundColor: isConnected
                    ? Colors.green.withOpacity(0.1)
                    : const Color(0xFFE3F2FD),
                child: Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: isConnected ? Colors.green : primaryDark,
                  size: 20,
                ),
              ),
              title: Text(
                result.device.name.isNotEmpty
                    ? result.device.name
                    : 'Unknown Device',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.black87,
                ),
              ),
              subtitle: Text(
                result.device.id.id,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: SizedBox(
                height: 32,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isConnected ? Colors.grey[400] : primaryLight,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    elevation: 0,
                  ),
                  onPressed: (isConnecting || isConnected)
                      ? null
                      : () => connectToDevice(result.device),
                  child: Text(
                    isConnected ? 'Đã kết nối' : 'Kết nối',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

Widget _buildTerminalList() {
    return Expanded(
      child: Container(
        margin: EdgeInsets.zero,
        decoration: BoxDecoration(
          // Nền trắng mờ (để chữ dễ đọc hơn trên nền app)
          color: Colors.white.withOpacity(0.6), 
          
          borderRadius: BorderRadius.circular(16),
          
          // --- VIỀN ĐẬM MÀU CHỦ ĐẠO (Xanh Ngọc) ---
          border: Border.all(
            color: primaryLight, // Dùng màu xanh sáng
            width: 2.0, // Viền dày hơn
          ),
          
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
                    // Tiêu đề cũng đổi sang màu xanh đậm cho hợp
                    const Text(
                      'TERMINAL LOG',
                      style: TextStyle(
                        color: primaryDark, 
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                    Row(
                      children: [
                        SizedBox(
                            height: 20,
                            width: 20,
                            child: Checkbox(
                                value: _logAddTime,
                                onChanged: (v) =>
                                    setState(() => _logAddTime = v ?? false),
                                activeColor: primaryDark,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4)))),
                        const SizedBox(width: 4),
                        const Text('Time', style: TextStyle(fontSize: 12, color: primaryDark)),
                        const SizedBox(width: 12),
                        InkWell(
                            onTap: () => setState(() => _logs.clear()),
                            child: const Icon(Icons.delete_sweep,
                                color: Colors.redAccent, size: 22))
                      ],
                    )
                  ],
                ),
              ),
              const Divider(height: 1, color: primaryLight), // Đường kẻ ngang cũng màu xanh
              Expanded(
                child: Stack(
                  children: [
                    // Logo nền mờ
                    Positioned.fill(
                      child: Center(
                        child: Opacity(
                          opacity: 0.08,
                          child: Image.asset(
                            'assets/TP.png',
                            width: 200,
                            fit: BoxFit.contain,
                            errorBuilder: (c, e, s) => const SizedBox(),
                          ),
                        ),
                      ),
                    ),
                    // List log
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
                              fontWeight: FontWeight.w600, // Chữ đậm hơn xíu cho dễ đọc
                              color: isRX ? Colors.green[800] : primaryDark, // TX dùng màu xanh đậm chủ đạo
                            ),
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

Widget _buildFloatingBottomArea(bool isKeyboardOpen) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.transparent, 
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 50, // Tăng chiều cao lên xíu cho đẹp
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30), // Bo tròn nhiều hơn
                      
                      // --- VIỀN ĐẬM MÀU XANH ĐẬM (Primary Dark) ---
                      border: Border.all(
                        color: primaryLight, 
                        width: 2.0, 
                      ),
                      
                      // --- HIỆU ỨNG BÓNG ĐỔ MÀU XANH ---
                      boxShadow: [
                        BoxShadow(
                          color: primaryDark.withOpacity(0.3), // Bóng màu xanh đậm
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        )
                      ],
                    ),
                    child: Row(children: [
                      const SizedBox(width: 20),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          enabled: connectedDevice != null,
                          textInputAction: TextInputAction.send,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: primaryDark),
                          decoration: InputDecoration(
                            hintText: 'Nhập lệnh cần gửi xuống thiết bị...',
                            hintStyle: TextStyle(color: Colors.grey[400]),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (_) => sendTextCommand(),
                        ),
                      ),
                      
                      // Nút Gửi
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: connectedDevice == null ? null : sendTextCommand,
                          borderRadius: BorderRadius.circular(30),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              // Nút gửi dùng Gradient cho đồng bộ với Header
                              gradient: connectedDevice != null 
                                ? const LinearGradient(colors: [primaryDark, primaryLight], begin: Alignment.topLeft, end: Alignment.bottomRight)
                                : null,
                              color: connectedDevice == null ? Colors.grey[300] : null,
                            ),
                            child: const Icon(Icons.send,
                                color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _manualCheckForUpdate() async {
    final updateInfo = UpdateService().updateAvailable.value;
    if (updateInfo != null) {
      UpdateService().showUpdateDialog(context, updateInfo);
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Đang kiểm tra cập nhật...'),
              ],
            ),
          ),
        ),
      ),
    );
    AppVersionInfo? newUpdate;
    try {
      newUpdate = await UpdateService().checkForUpdate();
    } catch (e) {
      debugPrint('❌ Lỗi manual check update: $e');
    } finally {
      if (mounted) Navigator.of(context).pop();
    }

    if (newUpdate != null) {
      if (mounted) UpdateService().showUpdateDialog(context, newUpdate);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ứng dụng đã là phiên bản mới nhất')),
        );
      }
    }


  }

  Widget _buildModernDrawer() {
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity, padding: const EdgeInsets.only(top: 50, bottom: 20, left: 20), decoration: const BoxDecoration(gradient: LinearGradient(colors: [primaryDark, primaryLight], begin: Alignment.topLeft, end: Alignment.bottomRight)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)), child: const CircleAvatar(radius: 30, backgroundColor: Colors.white, child: Icon(Icons.person, size: 40, color: primaryDark))), const SizedBox(height: 12), const Text('iDMAV 1.1.5', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)), const Text('Administrator', style: TextStyle(color: Colors.white70, fontSize: 14))]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(vertical: 10), children: [
              _buildDrawerItem(Icons.settings, 'Tốc độ nhấp nháy', () {Navigator.pop(context); _showSpeedDialog();}),
              _buildDrawerItem(Icons.brightness_6, 'Độ sáng', () {Navigator.pop(context); _showBrightnessDialog();}),
              const Divider(indent: 20, endIndent: 20),
              _buildDrawerItem(Icons.folder_copy, 'Lưu trữ & Chia sẻ', () {Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (ctx) => const ShareDataPage()));}),
              ValueListenableBuilder<AppVersionInfo?>(
                valueListenable: UpdateService().updateAvailable,
                builder: (context, updateInfo, _) {
                  return _buildDrawerItem(
                    Icons.system_update, 
                    'Kiểm tra cập nhật', 
                    () {
                      Navigator.pop(context);
                      _manualCheckForUpdate();
                    },
                    trailing: updateInfo != null 
                      ? Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                  );
                },
              ),
            ]),
          ),
          const Divider(),
          _buildDrawerItem(Icons.info_outline, 'Thông tin phần mềm', () {Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (ctx) => const AboutPage()));}, color: Colors.grey[700]!),
          _buildDrawerItem(Icons.logout, 'Đăng xuất', () => _logout(context), color: Colors.red),


          const Padding(
            padding: EdgeInsets.only(right: 16, top: 10, bottom: 20),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
              'Phiên bản 1.1.5',
              style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerItem(IconData icon, String title, VoidCallback onTap, {Color? color, Widget? trailing}) {
    Color itemColor = color ?? primaryDark;
    return ListTile(
      leading: Icon(icon, color: itemColor, size: 22), 
      title: Text(title, style: TextStyle(color: itemColor, fontWeight: FontWeight.w500)), 
      trailing: trailing,
      onTap: onTap, 
      contentPadding: const EdgeInsets.symmetric(horizontal: 24), 
      horizontalTitleGap: 10, 
      dense: true,
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
        backgroundColor: const Color(0xFFF5F7FA), resizeToAvoidBottomInset: false,
        appBar: AppBar(title: const Text('Bảng điều khiển', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), centerTitle: true, backgroundColor: Colors.transparent, flexibleSpace: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [primaryDark, primaryLight]))), elevation: 0, systemOverlayStyle: SystemUiOverlayStyle.light),
        drawer: _buildModernDrawer(),
        body: Stack(
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [const SizedBox(height: 16), _buildHeaderCard(), _buildDeviceList(), _buildTerminalList(), SizedBox(height: isKeyboardOpen ? 60 : 70)])),
            Positioned(left: 0, right: 0, bottom: keyboardHeight, child: _buildFloatingBottomArea(isKeyboardOpen)),
          ],
        ),
      ),
    );
  }
}

// Helper class cho StatefulBuilder trong Dialog để code gọn hơn
class StateBuilder extends StatefulWidget {
  final StatefulWidgetBuilder builder;
  const StateBuilder({Key? key, required this.builder}) : super(key: key);
  @override
  _StateBuilderState createState() => _StateBuilderState();
}
class _StateBuilderState extends State<StateBuilder> {
  @override
  Widget build(BuildContext context) => widget.builder(context, setState);
}