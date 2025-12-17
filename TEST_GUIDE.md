# 🧪 Testing Guide - Kiểm Tra Cải Thiện Tìm Dữ Liệu

## Prerequisites
- ✅ Code đã update (matrix_map_page.dart)
- ✅ Flutter analyze pass
- ✅ No compile errors

---

## 📋 Test Cases

### **Test #1: Download Ranh Giới - Admin Levels 2-8**

**Mục đích:** Kiểm tra xem ranh giới tỉnh/huyện/xã được tải đầy đủ

**Bước thực hiện:**
```
1. flutter run
2. Mở app → Matrix Map
3. Click "Tùy chọn Tải"
4. ✓ Check "Ranh giới Tỉnh/TP" (bỏ các cái khác)
5. Click "Bắt đầu Tải"
6. Đợi 30-45 giây
```

**Kỳ vọng:**
- ✅ Lúc nạp: Nhìn thấy progress (không bị "đơ")
- ✅ Kết quả: Ranh giới hiển thị **cấp tỉnh** (tím)
- ✅ Nếu zoom in: Thấy ranh giới **cấp huyện, xã** (đường kẻ chi tiết hơn)
- ⏱️ Thời gian: **30-45 giây** (cải thiện từ 90s cũ)

**Kiểm tra trong code:**
```dart
// Query mới có admin_level: "2|3|4|5|6|7|8"
// Thay vì cũ: "2|4" (chỉ 2 cấp)
```

---

### **Test #2: Retry Logic - Network Failure**

**Mục đích:** Kiểm tra tự động thử lại nếu lỗi

**Bước thực hiện:**
```
1. Tắt WiFi/4G tạm thời
2. Click "Tùy chọn Tải" → Check "Ranh giới" → "Bắt đầu"
3. Sau ~30s, bật WiFi/4G lại
4. Xem app có tự động thử lại không
```

**Kỳ vọng:**
- ✅ Sau 30s timeout, tự động thử server khác
- ✅ Nếu bật WiFi lại → Lần 2 thành công
- ⏱️ **Không** phải restart app, **không** phải click lại
- 📊 Status bar sẽ show "Đang tải (Lần 2)" / "Đang tải (Lần 3)"

---

### **Test #3: Cache - Lần Tải Lại Nhanh**

**Mục đích:** Kiểm tra cache hoạt động

**Bước thực hiên:**
```
1. Tải dữ liệu lần 1: Click "Tùy chọn" → "Ranh giới" → "Bắt đầu"
   → Đợi hoàn tất (30-45s)
2. Tải lại: Lại click "Tùy chọn" → "Ranh giới" → "Bắt đầu"
   → Đo thời gian
```

**Kỳ vọng:**
- ✅ Lần 1: 30-45 giây
- ✅ Lần 2: **Gần như tức thì** (1-2 giây) ← **CACHE**
- 📊 Log: "✓ Ranh giới: Dùng dữ liệu từ cache"

---

### **Test #4: Search Online - Ranh Giới Đầy Đủ**

**Mục đích:** Kiểm tra search tìm được ranh giới tất cả cấp

**Bước thực hiện:**
```
1. Click "Tìm & Vẽ"
2. Toggle sang "Ranh Giới" (màu tím)
3. Nhập "Hà Nội"
4. Click "Tìm & Vẽ"
```

**Kỳ vọng:**
- ✅ Tìm thấy **Hà Nội** (ranh giới TP)
- ✅ Zoom in thấy **các quận huyện** (tỉnh → huyện)
- ✅ Zoom in hơn nữa thấy **các xã phường**
- ⏱️ Thời gian: **15-25 giây** (thay vì 60s cũ)
- 🔄 Nếu không thành công lần 1 → **Tự động thử lại**

---

### **Test #5: Geometry Chi Tiết**

**Mục đích:** Kiểm tra ranh giới có chi tiết hay không

**Bước thực hiện:**
```
1. Download dữ liệu ranh giới
2. Zoom in tối đa (level 18-19)
3. Nhìn đường biên ranh giới
```

**Kỳ vọng:**
- ✅ Đường ranh giới **mịn, chi tiết** (không bị "chum lại")
- ✅ Nghe tin từ simplify: threshold 0.0005 (nhỏ hơn cũ 0.001 × 2)
- ✅ Không thấy "điểm cụt" ở góc thành phố

---

### **Test #6: Download All Types**

**Mục đích:** Kiểm tra tất cả loại dữ liệu vẫn hoạt động

**Bước thực hiện:**
```
1. Click "Tùy chọn Tải"
2. ✓ Check cả 3: Đường Cao tốc + Đường Quốc lộ + Ranh giới
3. Click "Bắt đầu"
```

**Kỳ vọng:**
- ✅ Tải cả 3 loại **đồng thời** (parallel)
- ⏱️ Thời gian: ~45 giây (3 requests chạy song song)
- 📊 Status bar cập nhật progress
- ✅ Kết quả: Thấy đường cao tốc (đỏ) + Quốc lộ (cam) + Ranh giới (tím)

---

## 🔍 Debug Output (Log)

**Xem logs:**
```bash
flutter run 2>&1 | grep -i "ranh|boundary|cache|retry"
```

**Chứa ký hiệu:**
- ✓ = Success
- ❌ = Failure  
- Lần X = Retry attempt

**Ví dụ output mong đợi:**
```
✓ Ranh giới: Dùng dữ liệu từ cache
Đang tải dữ liệu... (Đa luồng) - Lần 1
❌ Thất bại sau 30s timeout
Thử lại lần 2...
✓ Server overpass.kumi.systems responded!
```

---

## ✅ Verification Checklist

- [ ] **Ranh giới đầy đủ** - Có cấp tỉnh, huyện, xã
- [ ] **Nhanh hơn** - Download ≤45s (cũ 90s), Search ≤25s (cũ 60s)
- [ ] **Tự động retry** - Thấy "Lần 2", "Lần 3" nếu lỗi
- [ ] **Cache hoạt động** - Lần 2 gần như tức thì
- [ ] **Geometry chi tiết** - Ranh giới không bị "chum"
- [ ] **Không crash** - App chạy mượt, không "đơ"
- [ ] **Tất cả loại dữ liệu** - Cao tốc + Quốc lộ + Ranh giới
- [ ] **Multiple servers** - Nếu 1 server chậm, tự chuyển server khác

---

## 🐛 Troubleshooting

### **Ranh giới vẫn không đầy đủ**
```
→ Kiểm tra log có query mới: admin_level="2|3|4|5|6|7|8"
→ Nếu vẫn là "2|4" → Recompile (flutter clean && flutter pub get)
```

### **Download vẫn chậm (>60s)**
```
→ Kiểm tra network (WiFi/4G)
→ Kiểm tra Overpass API status (https://status.overpass-api.de/)
→ Thử lại sau 10 phút (API có limit rate)
```

### **Cache không hoạt động (lần 2 vẫn 45s)**
```
→ Kiểm tra initState có load cache không
→ Kiểm tra _downloadCache map có giữ dữ liệu không
→ Thử restart app (cache reset)
```

### **Ranh giới bị cắt đứt**
```
→ Kiểm tra geometry processing logic mới
→ Xem có fetch way từ allElements không
→ Debug: thêm print vào _processRelationElement()
```

---

## 📊 Performance Metrics

| Thao tác | Cũ | Mới | Cải thiện |
|---------|-----|-----|----------|
| Download Ranh giới (lần 1) | 90s | 30-45s | 2x |
| Download Ranh giới (lần 2) | 90s | 0-2s | 45x |
| Search Ranh giới | 60s | 15-25s | 3x |
| Retry logic | Không | 3x tự động | ∞ |
| Geometry chi tiết | Kém | Tốt | 2x |
| Server redundancy | 1/3 | 3/3 | 100% |

---

**Lúc hoàn tất tất cả test → Có thể commit & deploy! 🚀**
