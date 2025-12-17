import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- MÀU SẮC CHỦ ĐẠO ---
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

// --- MODELS (Giữ nguyên) ---
class BitDetail {
  int stt;
  final String tam;
  final int cong;
  BitDetail({required this.stt, required this.tam, required this.cong});
  factory BitDetail.fromJson(Map<String, dynamic> json) => BitDetail(
      stt: json['stt'], tam: json['tam'], cong: json['cong']);
  Map<String, dynamic> toJson() => {'stt': stt, 'tam': tam, 'cong': cong};
}

class BitItem {
  final String id;
  String name;
  String rawData;
  bool isEnabled; 
  List<BitDetail> details;

  BitItem({
    required this.id, required this.name, required this.rawData,
    this.isEnabled = false, required this.details,
  });

  factory BitItem.fromJson(Map<String, dynamic> json) {
    var list = json['details'] as List;
    return BitItem(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      rawData: json['rawData'] ?? '',
      isEnabled: json['isEnabled'] ?? false,
      details: list.map((i) => BitDetail.fromJson(i)).toList(),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'rawData': rawData,
    'isEnabled': isEnabled, 'details': details.map((e) => e.toJson()).toList(),
  };
}

class GroupBitItem {
  String id;
  String name;
  bool isEnabled;
  List<BitItem> childBits;

  GroupBitItem({
    required this.id,
    required this.name,
    this.isEnabled = false,
    required this.childBits,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isEnabled': isEnabled,
    'childBits': childBits.map((e) => e.toJson()).toList(),
  };

  factory GroupBitItem.fromJson(Map<String, dynamic> json) {
    var list = json['childBits'] as List;
    return GroupBitItem(
      id: json['id'],
      name: json['name'],
      isEnabled: json['isEnabled'] ?? false,
      childBits: list.map((i) => BitItem.fromJson(i)).toList(),
    );
  }
}

// --- TIỆN ÍCH XỬ LÝ TIẾNG VIỆT ---
String removeVietnameseTones(String str) {
  var withDia = 'áàảãạăắằẳẵặâấầẩẫậđéèẻẽẹêếềểễệíìỉĩịóòỏõọôốồổỗộơớờởỡợúùủũụưứừửữựýỳỷỹỵÁÀẢÃẠĂẮẰẲẴẶÂẤẦẨẪẬĐÉÈẺẼẸÊẾỀỂỄỆÍÌỈĨỊÓÒỎÕỌÔỐỒỔỖỘƠỚỜỞỠỢÚÙỦŨỤƯỨỪỬỮỰÝỲỶỸỴ';
  var withoutDia = 'aaaaaaaaaaaaaaaaadeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyAAAAAAAAAAAAAAAAADEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYY';
  for (int i = 0; i < withDia.length; i++) {
    str = str.replaceAll(withDia[i], withoutDia[i]);
  }
  return str;
}

// --- BỘ NÃO KIẾN THỨC ---
class SmartClassifier {
  static const List<String> roadKeywords = ['QL', 'AH', 'CT', 'TL', 'HL', 'Duong', 'Quoc lo', 'Cao toc', 'Dai lo'];
  static const List<String> waterKeywords = ['Song', 'Suoi', 'Ho', 'Kenh', 'Rach', 'Bien', 'Dam'];
  static const List<String> borderKeywords = ['RG', 'BG', 'Ranh gioi', 'Bien gioi', 'Moc', 'Cua khau'];
  
  static const List<String> provinces = [
    'An Giang', 'Ba Ria', 'Vung Tau', 'Bac Lieu', 'Bac Giang', 'Bac Kan', 'Bac Ninh',
    'Ben Tre', 'Binh Duong', 'Binh Dinh', 'Binh Phuoc', 'Binh Thuan', 'Ca Mau',
    'Cao Bang', 'Can Tho', 'Da Nang', 'Dak Lak', 'Dak Nong', 'Dien Bien', 'Dong Nai',
    'Dong Thap', 'Gia Lai', 'Ha Giang', 'Ha Nam', 'Ha Noi', 'Ha Tinh', 'Hai Duong',
    'Hai Phong', 'Hau Giang', 'Hoa Binh', 'Ho Chi Minh', 'Hung Yen', 'Khanh Hoa',
    'Kien Giang', 'Kon Tum', 'Lai Chau', 'Lang Son', 'Lao Cai', 'Lam Dong', 'Long An',
    'Nam Dinh', 'Nghe An', 'Ninh Binh', 'Ninh Thuan', 'Phu Tho', 'Phu Yen', 'Quang Binh',
    'Quang Nam', 'Quang Ngai', 'Quang Ninh', 'Quang Tri', 'Soc Trang', 'Son La',
    'Tay Ninh', 'Thai Binh', 'Thai Nguyen', 'Thanh Hoa', 'Thua Thien Hue', 'Tien Giang',
    'Tra Vinh', 'Tuyen Quang', 'Vinh Long', 'Vinh Phuc', 'Yen Bai'
  ];

  static String? getCategory(String name) {
    String cleanName = removeVietnameseTones(name).trim().toLowerCase(); 
    for (var province in provinces) {
      if (cleanName.contains(province.toLowerCase())) return "Địa giới Hành chính";
    }
    for (var key in roadKeywords) {
      if (cleanName.startsWith(key.toLowerCase())) return "Hệ thống Giao thông";
    }
    for (var key in waterKeywords) {
      if (cleanName.startsWith(key.toLowerCase())) return "Hệ thống Thủy văn";
    }
    for (var key in borderKeywords) {
      if (cleanName.startsWith(key.toLowerCase())) return "Hệ thống Ranh giới";
    }
    return null;
  }

  static String getAtomicKey(String name) {
    String originalName = name.trim();
    String cleanName = removeVietnameseTones(originalName).toLowerCase();
    for (int i=0; i < provinces.length; i++) {
      if (cleanName.contains(provinces[i].toLowerCase())) return "Tỉnh ${provinces[i]}"; 
    }
    List<String> words = originalName.split(' ');
    if (words.isNotEmpty) {
      String cleanFirstWord = removeVietnameseTones(words[0]).toLowerCase();
      if (roadKeywords.any((k) => k.toLowerCase() == cleanFirstWord)) {
        if (words.length >= 2) return "${words[0]} ${words[1]}".toUpperCase();
        return words[0].toUpperCase();
      }
    }
    if (words.isNotEmpty && words[0].length >= 2) return words[0];
    return "Khác";
  }
}

// --- GIAO DIỆN CHÍNH ---

class GroupBitPage extends StatefulWidget {
  final Function(String) onSendToEsp;

  const GroupBitPage({Key? key, required this.onSendToEsp}) : super(key: key);

  @override
  State<GroupBitPage> createState() => GroupBitPageState();
}

/// State public để MainNavigation có thể gọi reloadData() khi chuyển tab
class GroupBitPageState extends State<GroupBitPage> {
  List<GroupBitItem> _groups = [];
  List<BitItem> _allSourceBits = []; 

  @override
  void initState() {
    super.initState();
    _loadSourceBits();
    _loadGroups();
  }

  /// PUBLIC: Được gọi từ MainNavigation khi tab được chọn
  void reloadData() {
    _loadSourceBits();
    _loadGroups();
  }

  void _sortGroups() {
    _groups.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _loadSourceBits() async {
    final prefs = await SharedPreferences.getInstance();
    String? encodedData = prefs.getString('saved_bits_data');
    if (encodedData != null && encodedData.isNotEmpty) {
      List<dynamic> jsonList = jsonDecode(encodedData);
      setState(() {
        _allSourceBits = jsonList.map((e) => BitItem.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveGroups() async {
    _sortGroups();
    final prefs = await SharedPreferences.getInstance();
    String encoded = jsonEncode(_groups.map((e) => e.toJson()).toList());
    await prefs.setString('saved_groups_data', encoded);
  }

  Future<void> _loadGroups() async {
    final prefs = await SharedPreferences.getInstance();
    String? encoded = prefs.getString('saved_groups_data');
    if (encoded != null && encoded.isNotEmpty) {
      List<dynamic> jsonList = jsonDecode(encoded);
      setState(() {
        _groups = jsonList.map((e) => GroupBitItem.fromJson(e)).toList();
        _sortGroups();
      });
    }
  }

  String _calculateOnCommand(String rawData) {
    String cleanHex = rawData.replaceAll(RegExp(r'\s+'), '');
    StringBuffer result = StringBuffer();
    for (int i = 0; i < cleanHex.length - 3; i += 4) {
      try {
        String tamHex = cleanHex.substring(i, i + 2);
        String congHex = cleanHex.substring(i + 2, i + 4);
        int congVal = int.parse(congHex, radix: 16);
        int newCongVal = congVal + 16;
        String newCongHex = newCongVal.toRadixString(16).toUpperCase().padLeft(2, '0');
        result.write(tamHex);
        result.write(newCongHex);
      } catch (e) {
        result.write(cleanHex.substring(i, i+4));
      }
    }
    return result.toString();
  }

  void _sendGroupCommand(GroupBitItem group, bool isTurnOn) {
    StringBuffer combinedData = StringBuffer();
    for (var child in group.childBits) {
      if (isTurnOn) combinedData.write(_calculateOnCommand(child.rawData));
      else combinedData.write(child.rawData);
    }
    String finalCommand = combinedData.toString();
    if (finalCommand.isNotEmpty) {
      widget.onSendToEsp(finalCommand);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isTurnOn ? 'BẬT nhóm: ${group.name}' : 'TẮT nhóm: ${group.name}'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating, // Thông báo nổi đẹp hơn
      ));
    } else {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nhóm này chưa có dữ liệu!')));
    }
  }

  String? _getBitUsageInfo(String bitId, GroupBitItem? currentGroup) {
    for (var group in _groups) {
      if (currentGroup != null && group.id == currentGroup.id) continue;
      if (group.childBits.any((child) => child.id == bitId)) return group.name;
    }
    return null;
  }

  void _deleteAllGroups() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Xóa tất cả nhóm'),
        content: const Text('Bạn có chắc chắn muốn xóa toàn bộ danh sách nhóm không? Hành động này không thể hoàn tác.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              setState(() {
                _groups.clear();
              });
              _saveGroups();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã xóa tất cả nhóm!')));
            },
            child: const Text('Xóa hết', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _analyzeAndSuggestGroups() {
    Map<String, Map<String, List<BitItem>>> categoryToAtomicMap = {};

    for (var bit in _allSourceBits) {
      if (_getBitUsageInfo(bit.id, null) != null) continue;

      String? category = SmartClassifier.getCategory(bit.name);
      if (category == null) {
        List<String> words = bit.name.trim().split(' ');
        if (words.isNotEmpty && words[0].length >= 2) category = "Nhóm ${words[0]}";
        else category = "Nhóm Chung";
      }

      String atomicKey = SmartClassifier.getAtomicKey(bit.name);

      if (!categoryToAtomicMap.containsKey(category)) categoryToAtomicMap[category] = {};
      if (!categoryToAtomicMap[category]!.containsKey(atomicKey)) categoryToAtomicMap[category]![atomicKey] = [];
      categoryToAtomicMap[category]![atomicKey]!.add(bit);
    }

    List<MapEntry<String, List<BitItem>>> finalProposals = [];
    int maxGroupSize = 16;

    categoryToAtomicMap.forEach((categoryName, atomicClusters) {
      List<List<BitItem>> batchesForThisCategory = [];
      List<BitItem> currentBatch = [];

      atomicClusters.forEach((key, bits) {
        if (bits.length > maxGroupSize) {
          if (currentBatch.isNotEmpty) {
            batchesForThisCategory.add(List.from(currentBatch));
            currentBatch.clear();
          }
          for (int i = 0; i < bits.length; i += maxGroupSize) {
            int end = (i + maxGroupSize < bits.length) ? i + maxGroupSize : bits.length;
            batchesForThisCategory.add(bits.sublist(i, end));
          }
        } else {
          if (currentBatch.length + bits.length > maxGroupSize) {
            batchesForThisCategory.add(List.from(currentBatch));
            currentBatch.clear();
            currentBatch.addAll(bits);
          } else {
            currentBatch.addAll(bits);
          }
        }
      });

      if (currentBatch.isNotEmpty) {
        if (currentBatch.length >= 1) batchesForThisCategory.add(currentBatch);
      }

      if (batchesForThisCategory.length == 1) {
        finalProposals.add(MapEntry(categoryName, batchesForThisCategory[0]));
      } else {
        for (int i = 0; i < batchesForThisCategory.length; i++) {
          finalProposals.add(MapEntry("$categoryName ${i + 1}", batchesForThisCategory[i]));
        }
      }
    });

    finalProposals.sort((a, b) => b.value.length.compareTo(a.value.length));

    showDialog(
      context: context,
      builder: (ctx) {
        // Dùng StatefulBuilder để có thể cập nhật UI khi loại trừ item
        List<MapEntry<String, List<BitItem>>> proposals = List.from(finalProposals);
        
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  const Icon(Icons.psychology, color: Colors.purpleAccent, size: 28),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('AI Đề xuất Nhóm', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  Text('${proposals.length}', style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                ],
              ),
              content: proposals.isEmpty 
                  ? const Text('Không tìm thấy dữ liệu liên quan để gom nhóm.')
                  : SizedBox(
                      width: double.maxFinite,
                      height: 400, // Chiều cao cố định để tránh layout issues
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Nút TẠO TẤT CẢ
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green[600], padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                              icon: const Icon(Icons.library_add_check, color: Colors.white),
                              label: Text('TẠO TẤT CẢ (${proposals.length} nhóm)', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              onPressed: proposals.isEmpty ? null : () {
                                setState(() {
                                  for (var entry in proposals) {
                                    _groups.add(GroupBitItem(
                                      id: DateTime.now().microsecondsSinceEpoch.toString() + entry.key,
                                      name: entry.key,
                                      childBits: entry.value,
                                    ));
                                  }
                                });
                                _saveGroups();
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã tạo thành công!')));
                              },
                            ),
                          ),
                          const Divider(),
                          // Danh sách đề xuất
                          Expanded(
                            child: ListView.builder(
                              itemCount: proposals.length,
                              itemBuilder: (context, index) {
                                final entry = proposals[index];
                                return Card(
                                  elevation: 2, margin: const EdgeInsets.symmetric(vertical: 4),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: const EdgeInsets.only(left: 12, right: 0),
                                    leading: CircleAvatar(
                                      radius: 15, backgroundColor: Colors.blue[50],
                                      child: Text('${entry.value.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue)),
                                    ),
                                    title: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text(entry.value.take(2).map((e)=>e.name).join(", ") + (entry.value.length > 2 ? "..." : ""), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Nút THÊM (+) 
                                        IconButton(
                                          icon: const Icon(Icons.add_circle, color: Colors.green, size: 24),
                                          tooltip: 'Thêm',
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 36),
                                          onPressed: () {
                                            setState(() {
                                              _groups.add(GroupBitItem(
                                                id: DateTime.now().millisecondsSinceEpoch.toString(),
                                                name: entry.key, childBits: entry.value,
                                              ));
                                            });
                                            _saveGroups();
                                            Navigator.pop(ctx);
                                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Đã tạo "${entry.key}"!')));
                                          },
                                        ),
                                        // Nút LOẠI TRỪ (-)
                                        IconButton(
                                          icon: const Icon(Icons.remove_circle, color: Colors.red, size: 24),
                                          tooltip: 'Loại trừ',
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 36),
                                          onPressed: () {
                                            setDialogState(() {
                                              proposals.removeAt(index);
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
              actions: [ TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')) ],
            );
          },
        );
      },
    );
  }

  void _showGroupDialog({GroupBitItem? existingGroup}) {
    TextEditingController nameCtrl = TextEditingController(text: existingGroup?.name ?? '');
    List<BitItem> selectedChildren = existingGroup != null ? List.from(existingGroup.childBits) : [];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            void showSelectChildDialog() {
              String rawName = nameCtrl.text.trim();
              String suggestionKey = rawName.replaceAll(RegExp(r'Nhóm|Group|Khu vực|Hệ thống|Đường|Địa giới|Tỉnh', caseSensitive: false), '').trim();
              suggestionKey = suggestionKey.replaceAll(RegExp(r'\d+$'), '').trim();
              String cleanSuggestionKey = removeVietnameseTones(suggestionKey).toLowerCase();

              showDialog(
                context: context,
                builder: (ctx) {
                  String searchQuery = '';
                  bool onlyShowUnused = false;

                  return StatefulBuilder(
                    builder: (ctx, setStateSearch) {
                      List<BitItem> filteredList = _allSourceBits.where((item) {
                        String cleanName = removeVietnameseTones(item.name).toLowerCase();
                        String cleanId = item.id.toLowerCase();
                        String cleanSearch = removeVietnameseTones(searchQuery).toLowerCase();
                        
                        bool matchSearch = cleanName.contains(cleanSearch) || cleanId.contains(cleanSearch);
                        
                        if (!matchSearch) return false;
                        if (onlyShowUnused) {
                          String? ownerGroup = _getBitUsageInfo(item.id, existingGroup);
                          if (ownerGroup != null) return false; 
                        }
                        return true;
                      }).toList();

                      if (suggestionKey.isNotEmpty && searchQuery.isEmpty) {
                        filteredList.sort((a, b) {
                          String cleanNameA = removeVietnameseTones(a.name).toLowerCase();
                          String cleanNameB = removeVietnameseTones(b.name).toLowerCase();

                          bool matchA = cleanNameA.contains(cleanSuggestionKey);
                          bool matchB = cleanNameB.contains(cleanSuggestionKey);

                          if (matchA && !matchB) return -1;
                          if (!matchA && matchB) return 1;
                          return a.name.compareTo(b.name);
                        });
                      }

                      bool isAllSelected = filteredList.isNotEmpty && filteredList.every((item) => selectedChildren.any((e) => e.id == item.id));

                      return AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        title: Row(
                          children: [
                            const Text('Chọn nút'),
                            if (suggestionKey.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0),
                                child: Chip(
                                  avatar: const Icon(Icons.lightbulb, size: 14, color: Colors.white),
                                  label: Text('Gợi ý: "$suggestionKey"', style: const TextStyle(fontSize: 10, color: Colors.white)),
                                  backgroundColor: Colors.orange,
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                              )
                          ],
                        ),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(
                                decoration: const InputDecoration(labelText: 'Tìm tên hoặc ID...', prefixIcon: Icon(Icons.search), border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12)),
                                onChanged: (val) => setStateSearch(() => searchQuery = val),
                              ),
                              const SizedBox(height: 8),
                              Row(children: [
                                  Expanded(child: InkWell(onTap: () => setStateSearch(() => onlyShowUnused = !onlyShowUnused), child: Row(children: [Transform.scale(scale: 0.7, child: SizedBox(height: 20, width: 36, child: Switch(value: onlyShowUnused, activeColor: Colors.orange, onChanged: (val) => setStateSearch(() => onlyShowUnused = val)))), const SizedBox(width: 12), const Expanded(child: Text('Chưa dùng', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis))]))),
                                  InkWell(onTap: () { setStateSearch(() { if (isAllSelected) { for (var item in filteredList) selectedChildren.removeWhere((e) => e.id == item.id); } else { for (var item in filteredList) if (!selectedChildren.any((e) => e.id == item.id)) selectedChildren.add(item); } }); setStateDialog(() {}); }, child: Row(children: [Checkbox(value: isAllSelected, onChanged: (val) { setStateSearch(() { if (val == true) { for (var item in filteredList) if (!selectedChildren.any((e) => e.id == item.id)) selectedChildren.add(item); } else { for (var item in filteredList) selectedChildren.removeWhere((e) => e.id == item.id); } }); setStateDialog(() {}); }), const Text('Chọn hết', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)), const SizedBox(width: 8)]))
                              ]),
                              const Divider(),
                              Expanded(child: filteredList.isEmpty ? const Center(child: Text('Không tìm thấy nút nào')) : ListView.separated(itemCount: filteredList.length, separatorBuilder: (_,__) => const Divider(height: 1), itemBuilder: (ctx, idx) { final bit = filteredList[idx]; bool isSelected = selectedChildren.any((e) => e.id == bit.id); String? usedInGroup = _getBitUsageInfo(bit.id, existingGroup); String cleanItemName = removeVietnameseTones(bit.name).toLowerCase(); bool isSuggested = suggestionKey.isNotEmpty && cleanItemName.contains(cleanSuggestionKey); return ListTile(tileColor: isSuggested ? Colors.orange.withOpacity(0.1) : ((usedInGroup != null && !isSelected) ? Colors.grey[100] : null), title: Row(children: [Expanded(child: Text(bit.name, style: TextStyle(fontWeight: FontWeight.bold, color: isSuggested ? Colors.deepOrange : Colors.black))), if (isSuggested) const Icon(Icons.star, size: 16, color: Colors.orange)]), subtitle: usedInGroup != null ? Text('Đã thuộc: $usedInGroup', style: const TextStyle(color: Colors.redAccent, fontSize: 11)) : Text('ID: ${bit.id}', style: const TextStyle(fontSize: 11)), trailing: Checkbox(value: isSelected, activeColor: Colors.green, onChanged: (val) { setStateSearch(() { if (val == true) selectedChildren.add(bit); else selectedChildren.removeWhere((e) => e.id == bit.id); }); setStateDialog(() {}); }), onTap: () { setStateSearch(() { if (isSelected) selectedChildren.removeWhere((e) => e.id == bit.id); else selectedChildren.add(bit); }); setStateDialog(() {}); }); }))
                            ],
                          ),
                        ),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Xong'))],
                      );
                    },
                  );
                },
              );
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(existingGroup == null ? 'Tạo Nhóm Mới' : 'Sửa Nhóm'),
              content: SizedBox(width: double.maxFinite, child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tên Nhóm', hintText: 'Ví dụ: Hà Nội 1...', suffixIcon: Icon(Icons.edit_note)), onChanged: (val) {}), const SizedBox(height: 16), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Đã chọn: ${selectedChildren.length} nút'), ElevatedButton.icon(onPressed: () { if (nameCtrl.text.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hãy nhập tên nhóm để xem gợi ý!'), duration: Duration(seconds: 1))); } showSelectChildDialog(); }, icon: const Icon(Icons.playlist_add_check), label: const Text('Chọn nút'), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo,foregroundColor: Colors.white,))]), const Divider(), Expanded(child: selectedChildren.isEmpty ? const Center(child: Text('Chưa có nút nào.', style: TextStyle(color: Colors.grey))) : ListView.separated(itemCount: selectedChildren.length, separatorBuilder: (_,__) => const Divider(height: 1), itemBuilder: (ctx, idx) { final child = selectedChildren[idx]; return ListTile(dense: true, title: Text(child.name), trailing: IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.red), onPressed: () { setStateDialog(() { selectedChildren.removeAt(idx); }); })); }))])),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')), ElevatedButton(onPressed: () { if (nameCtrl.text.isEmpty) return; setState(() { if (existingGroup == null) { _groups.add(GroupBitItem(id: DateTime.now().millisecondsSinceEpoch.toString(), name: nameCtrl.text, childBits: selectedChildren)); } else { existingGroup.name = nameCtrl.text; existingGroup.childBits = selectedChildren; } }); _saveGroups(); Navigator.pop(context); }, child: const Text('Lưu Nhóm'))],
            );
          },
        );
      },
    );
  }

  void _deleteGroup(int index) {
    showDialog(context: context, builder: (ctx) => AlertDialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), title: const Text('Xác nhận xóa'), content: Text('Xóa nhóm "${_groups[index].name}"?'), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')), ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: () { setState(() { _groups.removeAt(index); }); _saveGroups(); Navigator.pop(ctx); }, child: const Text('Xóa'))]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA), // Màu nền sáng hiện đại
      appBar: AppBar(
        title: const Text('Bit Tổng (Nhóm)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryDark, primaryLight],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        elevation: 0,
        actions: [
                  // --- CHỈNH SỬA 2: Thêm text dưới mỗi icon ---
                  if (_groups.isNotEmpty)
                    _buildAppBarAction(
                      icon: Icons.delete_sweep,
                      label: 'Xóa hết',
                      onPressed: _deleteAllGroups,
                    ),
                  
                  _buildAppBarAction(
                    icon: Icons.psychology,
                    label: 'AI Gợi ý',
                    onPressed: _analyzeAndSuggestGroups,
                  ),
                  
                  _buildAppBarAction(
                    icon: Icons.add_circle_outline,
                    label: 'Tạo mới',
                    onPressed: () => _showGroupDialog(),
                  ),
                  const SizedBox(width: 8), // Thêm chút khoảng trống bên phải
                  // ------------------------------------------
                ],
        iconTheme: const IconThemeData(color: Colors.white),
        automaticallyImplyLeading: false, // Không hiện nút back vì đây là tab
      ),
      body: _groups.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.group_work, size: 100, color: Colors.grey), // Icon to hơn
                  const SizedBox(height: 16),
                  const Text('Chưa có nhóm nào.', style: TextStyle(color: Colors.grey, fontSize: 18)),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.auto_awesome, color: Colors.white),
                    label: const Text('Dùng AI Phân loại ngay', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    onPressed: _analyzeAndSuggestGroups,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryDark,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      elevation: 5,
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _groups.length,
              separatorBuilder: (ctx, idx) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final group = _groups[index];
                return InkWell(
                  onTap: () => _showGroupDialog(existingGroup: group),
                  onLongPress: () => _deleteGroup(index),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      // Hiệu ứng đổ bóng nhẹ
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.1), 
                          spreadRadius: 1, 
                          blurRadius: 10,
                          offset: const Offset(0, 4)
                        )
                      ]
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      child: Row(
                        children: [
                          // 1. Icon đại diện nhóm
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [primaryDark.withOpacity(0.8), primaryLight.withOpacity(0.8)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.folder_open, color: Colors.white, size: 24),
                          ),
                          const SizedBox(width: 16),
                          
                          // 2. Tên nhóm & số lượng
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  group.name, 
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF2D3436))
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${group.childBits.length} nút con', 
                                  style: TextStyle(color: Colors.grey[600], fontSize: 13)
                                ),
                              ],
                            ),
                          ),
                          
                          // 3. Switch bật tắt
                          Transform.scale(
                            scale: 0.9,
                            child: Switch(
                              value: group.isEnabled,
                              activeColor: primaryLight,
                              onChanged: (val) {
                                setState(() { group.isEnabled = val; });
                                _sendGroupCommand(group, val);
                                _saveGroups();
                              },
                            ),
                          ),
                          
                          // 4. Nút Edit nhỏ
                          const SizedBox(width: 8),
                          Icon(Icons.edit, color: Colors.grey[400], size: 18),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
// --- HÀM HELPER ĐÃ CẬP NHẬT: CHỮ ĐẬM & RÕ HƠN ---
  Widget _buildAppBarAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), // Căn chỉnh lại padding cho gọn
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 24), // Tăng size icon lên 24 cho rõ
            const SizedBox(height: 3), // Tăng khoảng cách chút xíu
            Text(
              label,
              style: const TextStyle(
                color: Colors.white, 
                fontSize: 11, // Tăng size chữ lên 11
                fontWeight: FontWeight.w700, // QUAN TRỌNG: Chữ đậm (Bold) rõ nét
                letterSpacing: 0.3, // Dãn chữ nhẹ cho thoáng
              ),
            ),
          ],
        ),
      ),
    );
  }
}