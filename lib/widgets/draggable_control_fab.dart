import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Enum xác định vị trí popup buttons
enum _PopupPosition { above, below, left, right }

// MÀU SẮC CHỦ ĐẠO
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

/// Widget FAB kéo thả với popup menu cho 3 lệnh: BẬT / NHÁY / TẮT
class DraggableControlFAB extends StatefulWidget {
  final Function(String) onCommand;
  final bool isConnected;

  const DraggableControlFAB({
    Key? key,
    required this.onCommand,
    required this.isConnected,
  }) : super(key: key);

  @override
  State<DraggableControlFAB> createState() => _DraggableControlFABState();
}

class _DraggableControlFABState extends State<DraggableControlFAB>
    with SingleTickerProviderStateMixin {
  // Vị trí FAB
  double _xPos = 0;
  double _yPos = 0;
  bool _isExpanded = false;
  bool _isInitialized = false;

  // Animation
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutBack),
    );
    _loadPosition();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadPosition() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _xPos = prefs.getDouble('fab_x') ?? 0;
      _yPos = prefs.getDouble('fab_y') ?? 0;
      _isInitialized = true;
    });
  }

  Future<void> _savePosition() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fab_x', _xPos);
    await prefs.setDouble('fab_y', _yPos);
  }

  void _toggleExpand() {
    setState(() => _isExpanded = !_isExpanded);
    if (_isExpanded) {
      _animController.forward();
    } else {
      _animController.reverse();
    }
  }

  void _sendCommand(String cmd) {
    widget.onCommand(cmd);
    _toggleExpand();
  }

  // Xác định vị trí popup dựa trên vị trí FAB
  _PopupPosition _getPopupPosition(Size screenSize) {
    const double edgeThreshold = 80; // Ngưỡng xác định sát mép
    const double fabSize = 56;
    
    final bool nearLeft = _xPos < edgeThreshold;
    final bool nearRight = _xPos > screenSize.width - edgeThreshold - fabSize;
    final bool nearTop = _yPos < edgeThreshold + 50; // +50 cho status bar
    final bool nearBottom = _yPos > screenSize.height - edgeThreshold - 150;
    
    // Ưu tiên: sát mép trái/phải -> nằm dọc, sát mép trên/dưới -> đảo vị trí
    if (nearLeft) {
      return _PopupPosition.right; // 3 nút nằm dọc bên phải FAB
    } else if (nearRight) {
      return _PopupPosition.left; // 3 nút nằm dọc bên trái FAB
    } else if (nearTop) {
      return _PopupPosition.below; // 3 nút nằm ngang bên dưới FAB
    } else {
      return _PopupPosition.above; // Mặc định: 3 nút nằm ngang bên trên FAB
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) return const SizedBox.shrink();

    final screenSize = MediaQuery.of(context).size;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // Default position: góc phải dưới, phía trên bottom nav (khoảng 80px)
    if (_xPos == 0 && _yPos == 0) {
      _xPos = screenSize.width - 80;
      _yPos = screenSize.height - 200 - bottomPadding;
    }

    final popupPosition = _getPopupPosition(screenSize);

    return Stack(
      children: [
        // Overlay đóng menu khi tap ra ngoài
        if (_isExpanded)
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleExpand,
              child: Container(color: Colors.black26),
            ),
          ),

        // Các nút popup (chỉ hiện khi mở)
        if (_isExpanded) ..._buildPositionedPopupButtons(popupPosition),

        // FAB chính (luôn ở vị trí _xPos, _yPos)
        Positioned(
          left: _xPos,
          top: _yPos,
          child: _buildMainFabButton(screenSize),
        ),
      ],
    );
  }

  // Tạo FAB chính - đổi icon thành X khi mở
  Widget _buildMainFabButton(Size screenSize) {
    return GestureDetector(
      onPanUpdate: _isExpanded ? null : (details) {
        setState(() {
          _xPos += details.delta.dx;
          _yPos += details.delta.dy;
          _xPos = _xPos.clamp(0, screenSize.width - 60);
          _yPos = _yPos.clamp(50, screenSize.height - 150);
        });
      },
      onPanEnd: _isExpanded ? null : (_) => _savePosition(),
      onTap: widget.isConnected ? _toggleExpand : null,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _isExpanded
                ? [const Color(0xFF667eea), const Color(0xFF764ba2)] // Tím khi mở
                : (widget.isConnected
                    ? [primaryDark, primaryLight]
                    : [Colors.grey, Colors.grey.shade400]),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (_isExpanded
                      ? Colors.purple
                      : (widget.isConnected ? primaryDark : Colors.grey))
                  .withOpacity(0.4),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          _isExpanded ? Icons.close : Icons.control_camera,
          color: Colors.white,
          size: 28,
        ),
      ),
    );
  }

  // Tạo các nút popup với vị trí chính xác dựa trên FAB
  List<Widget> _buildPositionedPopupButtons(_PopupPosition position) {
    const double fabSize = 56;
    const double buttonSpacing = 8;
    const double gap = 12; // Khoảng cách giữa FAB và popup buttons
    
    // Kích thước nút compact (chỉ icon) và full (icon + text)
    const double compactButtonSize = 46;
    const double fullButtonWidth = 100;
    const double fullButtonHeight = 44;
    
    final bool isHorizontal = position == _PopupPosition.above || position == _PopupPosition.below;
    
    final List<Map<String, dynamic>> buttons = [
      {'icon': Icons.power_settings_new, 'label': 'BẬT', 'color': Colors.green, 'command': 'Full'},
      {'icon': Icons.flash_on, 'label': 'NHÁY', 'color': Colors.orange, 'command': 'FB1'},
      {'icon': Icons.power_off, 'label': 'TẮT', 'color': Colors.red, 'command': 'Off'},
    ];
    
    List<Widget> positionedButtons = [];
    
    for (int i = 0; i < buttons.length; i++) {
      double left = 0;
      double top = 0;
      
      switch (position) {
        case _PopupPosition.above:
          // 3 nút nằm ngang phía trên FAB, căn giữa
          final totalWidth = 3 * compactButtonSize + 2 * buttonSpacing;
          final startX = _xPos + (fabSize - totalWidth) / 2;
          left = startX + i * (compactButtonSize + buttonSpacing);
          top = _yPos - gap - compactButtonSize;
          break;
          
        case _PopupPosition.below:
          // 3 nút nằm ngang phía dưới FAB, căn giữa
          final totalWidth = 3 * compactButtonSize + 2 * buttonSpacing;
          final startX = _xPos + (fabSize - totalWidth) / 2;
          left = startX + i * (compactButtonSize + buttonSpacing);
          top = _yPos + fabSize + gap;
          break;
          
        case _PopupPosition.right:
          // 3 nút nằm dọc bên phải FAB
          left = _xPos + fabSize + gap;
          final totalHeight = 3 * fullButtonHeight + 2 * buttonSpacing;
          final startY = _yPos + (fabSize - totalHeight) / 2;
          top = startY + i * (fullButtonHeight + buttonSpacing);
          break;
          
        case _PopupPosition.left:
          // 3 nút nằm dọc bên trái FAB
          left = _xPos - gap - fullButtonWidth;
          final totalHeight = 3 * fullButtonHeight + 2 * buttonSpacing;
          final startY = _yPos + (fabSize - totalHeight) / 2;
          top = startY + i * (fullButtonHeight + buttonSpacing);
          break;
      }
      
      positionedButtons.add(
        Positioned(
          left: left,
          top: top,
          child: _buildPopupButton(
            icon: buttons[i]['icon'],
            label: buttons[i]['label'],
            color: buttons[i]['color'],
            command: buttons[i]['command'],
            compact: isHorizontal,
          ),
        ),
      );
    }
    
    return positionedButtons;
  }

  Widget _buildPopupButton({
    required IconData icon,
    required String label,
    required Color color,
    required String command,
    bool compact = false,
  }) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: GestureDetector(
        onTap: widget.isConnected ? () => _sendCommand(command) : null,
        child: Container(
          padding: compact 
              ? const EdgeInsets.all(12) 
              : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(25),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
            border: Border.all(color: color.withOpacity(0.5), width: 2),
          ),
          child: compact
              ? Icon(icon, color: color, size: 22)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
