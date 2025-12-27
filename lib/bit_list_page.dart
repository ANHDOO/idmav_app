import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xml/xml.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// --- MÀU SẮC CHỦ ĐẠO ---
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

// --- MODELS ---
class BitDetail {
  int stt;
  final String tam;
  final int cong;

  BitDetail({required this.stt, required this.tam, required this.cong});

  Map<String, dynamic> toJson() => {'stt': stt, 'tam': tam, 'cong': cong};

  factory BitDetail.fromJson(Map<String, dynamic> json) {
    return BitDetail(
      stt: json['stt'],
      tam: json['tam'],
      cong: json['cong'],
    );
  }
}

class BitItem {
  final String id;
  String name;
  String rawData;
  bool isEnabled;
  List<BitDetail> details;

  BitItem({
    required this.id,
    required this.name,
    required this.rawData,
    this.isEnabled = false,
    required this.details,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rawData': rawData,
        'isEnabled': isEnabled,
        'details': details.map((e) => e.toJson()).toList(),
      };

  factory BitItem.fromJson(Map<String, dynamic> json) {
    var list = json['details'] as List;
    List<BitDetail> detailsList =
        list.map((i) => BitDetail.fromJson(i)).toList();

    return BitItem(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      rawData: json['rawData'] ?? '',
      isEnabled: json['isEnabled'] ?? false,
      details: detailsList,
    );
  }
}

// --- MAIN WIDGET ---

class BitListPage extends StatefulWidget {
  final Function(String) onSendToEsp;

  const BitListPage({Key? key, required this.onSendToEsp}) : super(key: key);

  @override
  State<BitListPage> createState() => BitListPageState();
}

enum SortType { idAsc, nameAsc }

class BitListPageState extends State<BitListPage> {
  List<BitItem> _bitItems = [];
  bool _isSelectionMode = false;
  Set<BitItem> _selectedItems = {};
  bool _isLoading = false;

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  SortType _currentSort = SortType.idAsc;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void reloadData() {
    _loadData();
  }

  // --- DATA METHODS ---
  Future<void> _saveData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String encodedData =
          jsonEncode(_bitItems.map((e) => e.toJson()).toList());
      await prefs.setString('saved_bits_data', encodedData);
    } catch (e) {
      print("Lỗi lưu data: $e");
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      String? encodedData = prefs.getString('saved_bits_data');
      if (encodedData != null && encodedData.isNotEmpty) {
        List<dynamic> jsonList = jsonDecode(encodedData);
        setState(() {
          _bitItems = jsonList.map((e) => BitItem.fromJson(e)).toList();
        });
      }
    } catch (e) {
      print("Lỗi tải data: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<BitItem> _getDisplayList() {
    List<BitItem> filtered = _bitItems.where((item) {
      return item.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          item.id.contains(_searchQuery);
    }).toList();

    filtered.sort((a, b) {
      if (_currentSort == SortType.nameAsc) {
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        int? idA = int.tryParse(a.id);
        int? idB = int.tryParse(b.id);
        if (idA != null && idB != null) {
          return idA.compareTo(idB);
        }
        return a.id.compareTo(b.id);
      }
    });
    return filtered;
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
        String newCongHex =
            newCongVal.toRadixString(16).toUpperCase().padLeft(2, '0');
        result.write(tamHex);
        result.write(newCongHex);
      } catch (e) {
        result.write(cleanHex.substring(i, i + 4));
      }
    }
    return result.toString();
  }

  String _rebuildRawDataFromDetails(List<BitDetail> details) {
    StringBuffer sb = StringBuffer();
    for (var detail in details) {
      sb.write(detail.tam);
      int rawCong = detail.cong - 1;
      String congHex = rawCong.toRadixString(16).toUpperCase().padLeft(2, '0');
      sb.write(congHex);
    }
    return sb.toString();
  }

  Future<void> _pickAndParseXml() async {
    setState(() => _isLoading = true);
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xml'],
      );

      if (result != null) {
        File file = File(result.files.single.path!);
        String content = await file.readAsString();
        final document = XmlDocument.parse(content);
        final bits = document.findAllElements('Bit');

        List<BitItem> parsedItems = [];
        for (var node in bits) {
          String id = node.getAttribute('ID') ?? '';
          String name = node.findElements('Name').single.text;
          String data = node.findElements('Data').single.text;

          if (data.isNotEmpty && data != '0') {
            List<BitDetail> details = _parseHexDataToDetails(data);
            parsedItems.add(BitItem(
              id: id,
              name: name,
              rawData: data,
              details: details,
              isEnabled: false,
            ));
          }
        }
        setState(() => _bitItems = parsedItems);
        _saveData();
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi: $e')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _generateXmlContent() {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="utf-8"');
    builder.element('DataBitDon', nest: () {
      Map<String, BitItem> itemMap = {};
      for (var item in _bitItems) {
        itemMap[item.id] = item;
      }
      for (int i = 1; i <= 160; i++) {
        String currentId = i.toString();
        if (itemMap.containsKey(currentId)) {
          var item = itemMap[currentId]!;
          builder.element('Bit', attributes: {'ID': currentId}, nest: () {
            builder.element('Name', nest: item.name);
            builder.element('Data', nest: item.rawData);
            builder.element('Status', nest: '0');
            builder.element('Color');
          });
        } else {
          builder.element('Bit', attributes: {'ID': currentId}, nest: () {
            builder.element('Name', nest: 'Trống');
            builder.element('Data', nest: '0');
            builder.element('Status', nest: '0');
            builder.element('Color');
          });
        }
      }
    });
    return builder.buildDocument().toXmlString(pretty: true);
  }

  Future<void> _saveToDevice() async {
    try {
      String xmlString = _generateXmlContent();
      Uint8List fileBytes = Uint8List.fromList(utf8.encode(xmlString));
      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Chọn nơi lưu file XML',
        fileName: 'DS_Export.xml',
        type: FileType.any,
        bytes: fileBytes,
      );
      if (outputFile != null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Đã lưu file tại: $outputFile')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi lưu file: $e')));
    }
  }

  Future<void> _shareFile() async {
    try {
      String xmlString = _generateXmlContent();
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/DS_Export.xml');
      await file.writeAsString(xmlString);
      await Share.shareXFiles([XFile(file.path)], text: 'File dữ liệu XML');
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi chia sẻ: $e')));
    }
  }

  void _showExportOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                  leading: const Icon(Icons.folder_special, color: primaryDark),
                  title: const Text('Lưu file (Save As...)'),
                  onTap: () {
                    Navigator.pop(context);
                    _saveToDevice();
                  }),
              ListTile(
                  leading: const Icon(Icons.share, color: primaryDark),
                  title: const Text('Chia sẻ (Share)'),
                  onTap: () {
                    Navigator.pop(context);
                    _shareFile();
                  }),
            ],
          ),
        );
      },
    );
  }

  void _addNewBitItem() {
    TextEditingController nameCtrl = TextEditingController();
    TextEditingController idCtrl =
        TextEditingController(text: (_bitItems.length + 1).toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Thêm Nút Mới'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Tên nút')),
            TextField(
                controller: idCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'ID (Tùy chọn)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: primaryDark),
            onPressed: () {
              if (nameCtrl.text.isNotEmpty) {
                setState(() {
                  _bitItems.add(BitItem(
                      id: idCtrl.text,
                      name: nameCtrl.text,
                      rawData: '',
                      details: [],
                      isEnabled: false));
                });
                _saveData();
                Navigator.pop(ctx);
                _showDetailDialog(_bitItems.last);
              }
            },
            child: const Text('Tạo', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _deleteSelectedItems() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Xác nhận xóa'),
        content: Text('Bạn muốn xóa ${_selectedItems.length} mục đã chọn?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              setState(() {
                _bitItems
                    .removeWhere((item) => _selectedItems.contains(item));
                _selectedItems.clear();
                _isSelectionMode = false;
              });
              _saveData();
              Navigator.pop(ctx);
            },
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  List<BitDetail> _parseHexDataToDetails(String hexString) {
    List<BitDetail> list = [];
    String cleanHex = hexString.replaceAll(RegExp(r'\s+'), '');
    int stt = 1;
    for (int i = 0; i < cleanHex.length - 3; i += 4) {
      try {
        String tamHex = cleanHex.substring(i, i + 2);
        String congHex = cleanHex.substring(i + 2, i + 4);
        int congValue = int.parse(congHex, radix: 16) + 1;
        list.add(BitDetail(stt: stt++, tam: tamHex, cong: congValue));
      } catch (e) {}
    }
    return list;
  }

  void _showDetailDialog(BitItem item) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            void updateItemRawData() {
              item.rawData = _rebuildRawDataFromDetails(item.details);
              _saveData();
            }

            void removeDetailRow(int index) {
              setStateDialog(() {
                item.details.removeAt(index);
                for (int i = 0; i < item.details.length; i++) {
                  item.details[i].stt = i + 1;
                }
              });
              updateItemRawData();
            }

            void addNewRow() {
              TextEditingController tamCtrl = TextEditingController();
              TextEditingController congCtrl = TextEditingController();
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  title: const Text('Thêm dữ liệu mới'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                          controller: tamCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Tấm (VD: 93)')),
                      TextField(
                          controller: congCtrl,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Cổng (VD: 16)')),
                    ],
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Hủy')),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: primaryDark),
                      onPressed: () {
                        if (tamCtrl.text.isNotEmpty &&
                            congCtrl.text.isNotEmpty) {
                          setStateDialog(() {
                            item.details.add(BitDetail(
                                stt: item.details.length + 1,
                                tam: tamCtrl.text.toUpperCase(),
                                cong: int.tryParse(congCtrl.text) ?? 0));
                          });
                          updateItemRawData();
                          Navigator.pop(ctx);
                        }
                      },
                      child: const Text('Thêm',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
            }

            return Dialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 600),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                            colors: [primaryDark, primaryLight]),
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(20)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(children: [
                              Expanded(
                                  child: Text(item.name,
                                      style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white),
                                      overflow: TextOverflow.ellipsis)),
                              IconButton(
                                  icon: const Icon(Icons.edit,
                                      color: Colors.white),
                                  onPressed: () async {
                                    await showDialog(
                                        context: context,
                                        builder: (ctx) {
                                          TextEditingController renameCtrl =
                                              TextEditingController(
                                                  text: item.name);
                                          return AlertDialog(
                                            title: const Text('Đổi tên nút'),
                                            content: TextField(
                                                controller: renameCtrl,
                                                autofocus: true),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(ctx),
                                                  child: const Text('Hủy')),
                                              ElevatedButton(
                                                  onPressed: () {
                                                    if (renameCtrl
                                                        .text.isNotEmpty) {
                                                      item.name =
                                                          renameCtrl.text;
                                                      _saveData();
                                                      Navigator.pop(ctx);
                                                    }
                                                  },
                                                  child: const Text('Lưu'))
                                            ],
                                          );
                                        });
                                    setStateDialog(() {});
                                    setState(() {});
                                  })
                            ]),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: primaryDark),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Thêm'),
                            onPressed: addNewRow,
                          )
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: DataTable(
                          columnSpacing: 10,
                          columns: const [
                            DataColumn(
                                label: Text('STT',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold))),
                            DataColumn(
                                label: Text('Tấm',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold))),
                            DataColumn(
                                label: Text('Cổng',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold))),
                            DataColumn(
                                label: Text('Xóa',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold))),
                          ],
                          rows: item.details.asMap().entries.map((entry) {
                            return DataRow(
                              color: MaterialStateProperty.resolveWith<Color?>(
                                  (states) => entry.value.stt % 2 == 0
                                      ? Colors.grey[100]
                                      : null),
                              cells: [
                                DataCell(Text(entry.value.stt.toString())),
                                DataCell(Text(entry.value.tam)),
                                DataCell(Text(entry.value.cong.toString())),
                                DataCell(IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.red),
                                    onPressed: () =>
                                        removeDetailRow(entry.key))),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Đóng'))),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _toggleSelectionMode(BitItem item) {
    setState(() {
      _isSelectionMode = true;
      _selectedItems.add(item);
    });
  }

  void _toggleItemSelection(BitItem item) {
    setState(() {
      if (_selectedItems.contains(item)) {
        _selectedItems.remove(item);
        if (_selectedItems.isEmpty) _isSelectionMode = false;
      } else {
        _selectedItems.add(item);
      }
    });
  }

  // --- HÀM HELPER: TẠO NÚT CÓ TEXT BÊN DƯỚI CHO APPBAR ---
  Widget _buildAppBarAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color ?? Colors.white, size: 24),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: color ?? Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<BitItem> displayList = _getDisplayList();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                    hintText: 'Tìm kiếm tên hoặc ID...',
                    hintStyle: TextStyle(color: Colors.white70),
                    border: InputBorder.none),
                autofocus: true,
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val;
                  });
                },
              )
            : (_isSelectionMode
                ? Text('Đã chọn: ${_selectedItems.length}',
                    style: const TextStyle(color: Colors.white))
                : const Text('Danh sách Bít',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white))),
        flexibleSpace: _isSelectionMode
            ? null
            : Container(
                decoration: const BoxDecoration(
                    gradient:
                        LinearGradient(colors: [primaryDark, primaryLight]))),
        backgroundColor:
            _isSelectionMode ? Colors.grey[800] : Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        automaticallyImplyLeading: false,
        leading: _isSearching
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _isSearching = false;
                    _searchQuery = '';
                    _searchController.clear();
                  });
                })
            : (_isSelectionMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _isSelectionMode = false;
                        _selectedItems.clear();
                      });
                    })
                : null),
        actions: _isSelectionMode
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _selectedItems.length == _bitItems.length &&
                            _bitItems.isNotEmpty,
                        tristate: true,
                        onChanged: (val) {
                          setState(() {
                            if (_selectedItems.length == _bitItems.length) {
                              _selectedItems.clear();
                              _isSelectionMode = false;
                            } else {
                              _selectedItems = _bitItems.toSet();
                            }
                          });
                        },
                        activeColor: Colors.white,
                        checkColor: Colors.red,
                        side: const BorderSide(color: Colors.white, width: 2),
                      ),
                      const Text('Tất cả',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                _buildAppBarAction(
                  icon: Icons.delete,
                  label: 'Xóa',
                  onPressed: _deleteSelectedItems,
                  color: Colors.redAccent,
                ),
              ]
            : [
                if (!_isSearching)
                  _buildAppBarAction(
                    icon: Icons.search,
                    label: 'Tìm',
                    onPressed: () {
                      setState(() {
                        _isSearching = true;
                      });
                    },
                  ),
                if (!_isSearching)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.filter_list,
                              color: Colors.white, size: 24),
                          const SizedBox(height: 3),
                          const Text('Lọc',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    onTap: () {
                      final RenderBox button =
                          context.findRenderObject() as RenderBox;
                      final RenderBox overlay = Overlay.of(context)
                          .context
                          .findRenderObject() as RenderBox;
                      final RelativeRect position = RelativeRect.fromRect(
                        Rect.fromPoints(
                          button.localToGlobal(Offset.zero, ancestor: overlay),
                          button.localToGlobal(
                              button.size.bottomRight(Offset.zero),
                              ancestor: overlay),
                        ),
                        Offset.zero & overlay.size,
                      );
                      showMenu<SortType>(
                        context: context,
                        position: position,
                        items: [
                          const PopupMenuItem(
                              value: SortType.idAsc,
                              child: Text('Sắp xếp theo ID (1-9)')),
                          const PopupMenuItem(
                              value: SortType.nameAsc,
                              child: Text('Sắp xếp theo Tên (A-Z)')),
                        ],
                      ).then((value) {
                        if (value != null) {
                          setState(() {
                            _currentSort = value;
                          });
                        }
                      });
                    },
                  ),
                _buildAppBarAction(
                  icon: Icons.add_circle_outline,
                  label: 'Thêm',
                  onPressed: _addNewBitItem,
                ),
                _buildAppBarAction(
                  icon: Icons.save_as,
                  label: 'Xuất',
                  onPressed: _showExportOptions,
                ),
                const SizedBox(width: 4),
              ],
      ),
      body: Column(
        children: [
          if (_bitItems.isEmpty)
            Expanded(
              child: Center(
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_open,
                              size: 80, color: Colors.grey[300]),
                          const SizedBox(height: 16),
                          const Text("Chưa có dữ liệu",
                              style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryDark,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30)),
                            ),
                            icon: const Icon(Icons.upload_file,
                                color: Colors.white),
                            label: const Text('Nhập file XML',
                                style: TextStyle(color: Colors.white)),
                            onPressed: _pickAndParseXml,
                          ),
                        ],
                      ),
              ),
            )
          else
            Expanded(
              child: displayList.isEmpty
                  ? const Center(
                      child: Text('Không tìm thấy kết quả',
                          style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: displayList.length,
                      separatorBuilder: (ctx, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final item = displayList[index];
                        final isSelected = _selectedItems.contains(item);

                        return InkWell(
                          onTap: () {
                            if (_isSelectionMode)
                              _toggleItemSelection(item);
                            else
                              _showDetailDialog(item);
                          },
                          onLongPress: () {
                            if (!_isSelectionMode) _toggleSelectionMode(item);
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 12, horizontal: 16),
                            decoration: BoxDecoration(
                                color: isSelected
                                    ? primaryLight.withOpacity(0.1)
                                    : Colors.white,
                                border: isSelected
                                    ? Border.all(color: primaryDark, width: 2)
                                    : Border.all(color: Colors.white),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.grey.withOpacity(0.1),
                                      spreadRadius: 1,
                                      blurRadius: 6,
                                      offset: const Offset(0, 3))
                                ]),
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                        colors: [
                                          primaryDark.withOpacity(0.8),
                                          primaryLight.withOpacity(0.8)
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Center(
                                    child: Text(item.id,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(item.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              color: Colors.black87)),
                                      const SizedBox(height: 4),
                                      Text('${item.details.length} chi tiết',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600])),
                                    ],
                                  ),
                                ),
                                if (_isSelectionMode)
                                  Checkbox(
                                      value: isSelected,
                                      activeColor: primaryDark,
                                      onChanged: (val) =>
                                          _toggleItemSelection(item))
                                else
                                  Transform.scale(
                                    scale: 0.9,
                                    child: Switch(
                                      value: item.isEnabled,
                                      activeColor: primaryLight,
                                      onChanged: (val) {
                                        setState(() {
                                          item.isEnabled = val;
                                        });
                                        _saveData();
                                        if (val == true) {
                                          String dataToSend =
                                              _calculateOnCommand(
                                                  item.rawData);
                                          widget.onSendToEsp(dataToSend);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                                  content: Text(
                                                      'BẬT: ${item.name}'),
                                                  duration: const Duration(
                                                      milliseconds: 500),
                                                  behavior: SnackBarBehavior
                                                      .floating));
                                        } else {
                                          widget.onSendToEsp(item.rawData);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                                  content: Text(
                                                      'TẮT: ${item.name}'),
                                                  duration: const Duration(
                                                      milliseconds: 500),
                                                  behavior: SnackBarBehavior
                                                      .floating));
                                        }
                                      },
                                    ),
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
      floatingActionButton: _bitItems.isNotEmpty
          ? FloatingActionButton.extended(
              backgroundColor: primaryDark,
              onPressed: _pickAndParseXml,
              icon: const Icon(Icons.folder_open, color: Colors.white),
              label: const Text('Mở File',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }
}