import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'home_page.dart';
import 'bit_list_page.dart';
import 'group_bit_page.dart';
import 'matrix_map_page.dart';
import 'scanner_page.dart';
import 'widgets/draggable_control_fab.dart';

// MÀU SẮC CHỦ ĐẠO
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

/// Widget wrapper chứa Bottom Navigation Bar với 5 tabs
class MainNavigation extends StatefulWidget {
  const MainNavigation({Key? key}) : super(key: key);

  @override
  State<MainNavigation> createState() => MainNavigationState();
}

class MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  // Keys để truy cập state của các trang con
  final GlobalKey<HomePageState> _homePageKey = GlobalKey<HomePageState>();
  final GlobalKey<BitListPageState> _bitListPageKey = GlobalKey<BitListPageState>();
  final GlobalKey<GroupBitPageState> _groupBitPageKey = GlobalKey<GroupBitPageState>();
  final GlobalKey<MatrixMapPageState> _mapPageKey = GlobalKey<MatrixMapPageState>();
  final GlobalKey<ScannerPageState> _scannerPageKey = GlobalKey<ScannerPageState>();

  // Biến lưu trạng thái kết nối để FAB có thể update
  bool _isConnected = false;
  
  // [MỚI] Chế độ full screen khi vào Dò Bít từ Bản đồ
  bool _isFullScreenMode = false;

  // Getter để các trang con có thể gọi sendLedCommand
  BluetoothDevice? get connectedDevice => _homePageKey.currentState?.connectedDevice;

  Future<void> sendLedCommand(String command) async {
    if (_homePageKey.currentState != null) {
      await _homePageKey.currentState!.sendLedCommand(command);
    }
  }

  /// Được gọi từ HomePage khi trạng thái kết nối thay đổi
  void notifyConnectionChanged(bool isConnected) {
    if (mounted && _isConnected != isConnected) {
      setState(() {
        _isConnected = isConnected;
      });
    }
  }

  /// Xử lý khi chuyển tab - reload data nếu cần
  void _onTabChanged(int index) {
    setState(() {
      _currentIndex = index;
      _isFullScreenMode = false; // Thoát chế độ full screen khi user nhấn tab
    });
    
    // Reload data khi chuyển đến tab cần refresh
    switch (index) {
      case 1: // Bit Đơn
        _bitListPageKey.currentState?.reloadData();
        break;
      case 2: // Bit Tổng
        _groupBitPageKey.currentState?.reloadData();
        break;
    }
  }

  /// PUBLIC: Được gọi từ MatrixMapPage để chuyển tới tab Scanner với dữ liệu
  void navigateToScanner({String? name, String? limitList}) {
    // Chuyển đến tab Scanner (index 4) với chế độ full screen
    setState(() {
      _currentIndex = 4;
      _isFullScreenMode = true; // Bật chế độ full screen
    });
    // Truyền dữ liệu từ Bản đồ sang Scanner (chỉ khi vào từ Bản đồ)
    _scannerPageKey.currentState?.setInitialData(name: name, limitList: limitList);
  }

  /// PUBLIC: Được gọi từ ScannerPage để quay lại Map
  void navigateToMap() {
    setState(() {
      _currentIndex = 3;
      _isFullScreenMode = false; // Thoát chế độ full screen
    });
  }

  /// Helper: Tạo một navigation item với hiệu ứng đẹp
  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, String label) {
    bool isActive = _currentIndex == index;
    
    return GestureDetector(
      onTap: () => _onTabChanged(index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: isActive ? 14 : 10,
          vertical: 6,
        ),
        decoration: isActive
            ? BoxDecoration(
                color: Colors.white.withOpacity(0.25),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.2),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              color: isActive ? Colors.white : Colors.white.withOpacity(0.85),
              size: isActive ? 26 : 24,
              shadows: isActive 
                  ? [Shadow(color: Colors.white.withOpacity(0.5), blurRadius: 10)]
                  : null,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white.withOpacity(0.85),
                fontSize: isActive ? 10 : 9,
                fontWeight: FontWeight.bold,
                shadows: isActive 
                    ? [Shadow(color: Colors.white.withOpacity(0.5), blurRadius: 5)]
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // === CONTENT PAGES (IndexedStack giữ state) ===
          IndexedStack(
            index: _currentIndex,
            children: [
              // Tab 0: Home (Điều khiển BLE)
              HomePage(
                key: _homePageKey,
                onConnectionChanged: notifyConnectionChanged,
              ),

              // Tab 1: Bit Đơn
              BitListPage(
                key: _bitListPageKey,
                onSendToEsp: (cmd) async => await sendLedCommand(cmd),
              ),

              // Tab 2: Bit Tổng
              GroupBitPage(
                key: _groupBitPageKey,
                onSendToEsp: (cmd) async => await sendLedCommand(cmd),
              ),

              // Tab 3: Bản Đồ
              MatrixMapPage(key: _mapPageKey),

              // Tab 4: Dò Bít
              ScannerPage(
                key: _scannerPageKey,
                onSendToEsp: (cmd) async => await sendLedCommand(cmd),
                // Chỉ truyền onBackToMap khi vào từ Bản đồ (full screen mode)
                onBackToMap: _isFullScreenMode ? navigateToMap : null,
              ),
            ],
          ),

          // === DRAGGABLE FAB (overlay trên tất cả) ===
          DraggableControlFAB(
            isConnected: _isConnected,
            onCommand: (cmd) async {
              if (_isConnected && _homePageKey.currentState != null) {
                await sendLedCommand(cmd);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Đã gửi: $cmd'),
                    duration: const Duration(milliseconds: 500),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Chưa kết nối Bluetooth!'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
          ),
        ],
      ),

      // === BOTTOM NAVIGATION BAR (Ẩn khi full screen mode) ===
      bottomNavigationBar: _isFullScreenMode ? null : Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.grey.shade100,
              Colors.white,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          boxShadow: [
            BoxShadow(
              color: primaryDark.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: SafeArea(
          child: Container(
            height: 65,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [primaryDark, primaryLight],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: primaryDark.withOpacity(0.4),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildNavItem(0, Icons.home_outlined, Icons.home_rounded, 'Home'),
                _buildNavItem(1, Icons.grid_view_outlined, Icons.grid_view_rounded, 'Bit Đơn'),
                _buildNavItem(2, Icons.layers_outlined, Icons.layers_rounded, 'Bit Tổng'),
                _buildNavItem(3, Icons.map_outlined, Icons.map_rounded, 'Bản Đồ'),
                _buildNavItem(4, Icons.radar_outlined, Icons.radar_rounded, 'Dò Bít'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

