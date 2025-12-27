#!/usr/bin/env python3
"""
Tạo dữ liệu ranh giới 2025 (34 tỉnh sau sáp nhập) từ GADM smoothed data
"""
import json
from datetime import datetime
from shapely.geometry import shape, mapping
from shapely.ops import unary_union

# Quy hoạch sáp nhập 2025 (Theo Nghị quyết Quốc hội chính thức - 34 đơn vị)
# I- 11 tỉnh/TP KHÔNG sáp nhập: Hà Nội, Huế, Lai Châu, Điện Biên, Sơn La, Lạng Sơn, Quảng Ninh, Thanh Hóa, Nghệ An, Hà Tĩnh, Cao Bằng
# II- 23 tỉnh/TP SAU sáp nhập

MERGE_2025 = {
    # 11 tỉnh/TP KHÔNG sáp nhập
    'Thành phố Hà Nội': ['Thủ Đô Hà Nội'],
    'Thành phố Huế': ['Thừa Thiên Huế'],
    'Tỉnh Lai Châu': ['Lai Châu'],
    'Tỉnh Điện Biên': ['Điện Biên'],
    'Tỉnh Sơn La': ['Sơn La'],
    'Tỉnh Lạng Sơn': ['Lạng Sơn'],
    'Tỉnh Quảng Ninh': ['Quảng Ninh'],
    'Tỉnh Thanh Hóa': ['Thanh Hóa'],
    'Tỉnh Nghệ An': ['Nghệ An'],
    'Tỉnh Hà Tĩnh': ['Hà Tĩnh'],
    'Tỉnh Cao Bằng': ['Cao Bằng'],
    
    # 23 tỉnh/TP SAU sáp nhập
    'Tỉnh Tuyên Quang': ['Tuyên Quang', 'Hà Giang'],                    # 1. Tuyên Quang + Hà Giang
    'Tỉnh Lào Cai': ['Lào Cai', 'Yên Bái'],                             # 2. Lào Cai + Yên Bái
    'Tỉnh Thái Nguyên': ['Thái Nguyên', 'Bắc Kạn'],                     # 3. Thái Nguyên + Bắc Kạn
    'Tỉnh Phú Thọ': ['Phú Thọ', 'Vĩnh Phúc', 'Hòa Bình'],              # 4. Phú Thọ + Vĩnh Phúc + Hòa Bình
    'Tỉnh Bắc Ninh': ['Bắc Ninh', 'Bắc Giang'],                        # 5. Bắc Ninh + Bắc Giang
    'Tỉnh Hưng Yên': ['Hưng Yên', 'Thái Bình'],                        # 6. Hưng Yên + Thái Bình
    'Thành phố Hải Phòng': ['TP. Hải Phòng', 'Hải Dương'],             # 7. Hải Phòng + Hải Dương
    'Tỉnh Ninh Bình': ['Ninh Bình', 'Hà Nam', 'Nam Định'],             # 8. Ninh Bình + Hà Nam + Nam Định
    'Tỉnh Quảng Trị': ['Quảng Trị', 'Quảng Bình'],                     # 9. Quảng Trị + Quảng Bình
    'Thành phố Đà Nẵng': ['TP. Đà Nẵng', 'Quảng Nam'],                 # 10. Đà Nẵng + Quảng Nam
    'Tỉnh Quảng Ngãi': ['Quảng Ngãi', 'Kon Tum'],                      # 11. Quảng Ngãi + Kon Tum
    'Tỉnh Gia Lai': ['Gia Lai', 'Bình Định'],                          # 12. Gia Lai + Bình Định
    'Tỉnh Khánh Hòa': ['Khánh Hòa', 'Ninh Thuận'],                     # 13. Khánh Hòa + Ninh Thuận
    'Tỉnh Lâm Đồng': ['Lâm Đồng', 'Đắk Nông', 'Bình Thuận'],          # 14. Lâm Đồng + Đắk Nông + Bình Thuận
    'Tỉnh Đắk Lắk': ['Đắk Lắk', 'Phú Yên'],                           # 15. Đắk Lắk + Phú Yên
    'Thành phố Hồ Chí Minh': ['TP. Hồ Chí Minh', 'Bình Dương', 'Bà Rịa - Vũng Tàu'],  # 16. TP.HCM + Bình Dương + Bà Rịa-Vũng Tàu
    'Tỉnh Đồng Nai': ['Đồng Nai', 'Bình Phước'],                       # 17. Đồng Nai + Bình Phước
    'Tỉnh Tây Ninh': ['Tây Ninh', 'Long An'],                          # 18. Tây Ninh + Long An
    'Thành phố Cần Thơ': ['TP. Cần Thơ', 'Sóc Trăng', 'Hậu Giang'],   # 19. Cần Thơ + Sóc Trăng + Hậu Giang
    'Tỉnh Vĩnh Long': ['Vĩnh Long', 'Bến Tre', 'Trà Vinh'],           # 20. Vĩnh Long + Bến Tre + Trà Vinh
    'Tỉnh Đồng Tháp': ['Đồng Tháp', 'Tiền Giang'],                    # 21. Đồng Tháp + Tiền Giang
    'Tỉnh Cà Mau': ['Cà Mau', 'Bạc Liêu'],                            # 22. Cà Mau + Bạc Liêu
    'Tỉnh An Giang': ['An Giang', 'Kiên Giang'],                      # 23. An Giang + Kiên Giang
}

def calculate_bbox(geometry):
    """Tính bounding box từ geometry coordinates"""
    min_lat, max_lat = 90, -90
    min_lng, max_lng = 180, -180
    
    geo_type = geometry.get('type', '')
    coords = geometry.get('coordinates', [])
    
    def process_ring(ring):
        nonlocal min_lat, max_lat, min_lng, max_lng
        for point in ring:
            if isinstance(point, (list, tuple)) and len(point) >= 2:
                lng, lat = point[0], point[1]
                min_lat = min(min_lat, lat)
                max_lat = max(max_lat, lat)
                min_lng = min(min_lng, lng)
                max_lng = max(max_lng, lng)
    
    if geo_type == 'Polygon':
        for ring in coords:
            process_ring(ring)
    elif geo_type == 'MultiPolygon':
        for polygon in coords:
            for ring in polygon:
                process_ring(ring)
    
    return [round(min_lat, 4), round(min_lng, 4), round(max_lat, 4), round(max_lng, 4)]

def merge_geometries(geometries):
    """Gộp và xóa đường biên giới chung giữa các geometry bằng Shapely"""
    try:
        # Convert GeoJSON dicts to Shapely objects
        shapely_geoms = [shape(g) for g in geometries]
        
        # Perform union (dissolve)
        merged = unary_union(shapely_geoms)
        
        # Convert back to GeoJSON dict
        return mapping(merged)
    except Exception as e:
        print(f"  ❌ Lỗi khi gộp geometry: {e}")
        # Fallback to simple concatenation if shapely fails
        all_polygons = []
        for geom in geometries:
            geo_type = geom.get('type', '')
            coords = geom.get('coordinates', [])
            if geo_type == 'Polygon':
                all_polygons.append(coords)
            elif geo_type == 'MultiPolygon':
                all_polygons.extend(coords)
        return {
            'type': 'MultiPolygon',
            'coordinates': all_polygons
        }

def create_2025_boundaries():
    # Load dữ liệu từ vn_boundaries.json (đã smoothed)
    with open('vn_boundaries.json', 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    # Tạo dict lookup theo tên
    province_map = {}
    country_geom = None
    
    for feat in data.get('features', []):
        name = feat.get('name', '')
        if feat.get('type') == 'country':
            country_geom = feat.get('geometry')
        else:
            province_map[name] = feat.get('geometry', {})
    
    features = []
    
    # Thêm quốc gia Việt Nam trước
    if country_geom:
        bbox = calculate_bbox(country_geom)
        features.append({
            'name': 'Việt Nam',
            'type': 'country',
            'admin_level': 2,
            'bbox': bbox,
            'geometry': country_geom
        })
        print(f"  ✅ Việt Nam (country)")
    
    # Xử lý từng tỉnh/nhóm sáp nhập
    processed = set()
    
    for new_name, old_names in MERGE_2025.items():
        geometries = []
        found = []
        
        for old_name in old_names:
            if old_name in province_map:
                geometries.append(province_map[old_name])
                found.append(old_name)
                processed.add(old_name)
        
        if not geometries:
            print(f"  ⚠️ Không tìm thấy: {new_name} (cần: {old_names})")
            continue
        
        # Gộp geometry nếu có nhiều tỉnh
        if len(geometries) == 1:
            merged_geom = geometries[0]
        else:
            merged_geom = merge_geometries(geometries)
        
        bbox = calculate_bbox(merged_geom)
        
        features.append({
            'name': new_name,
            'type': 'province',
            'admin_level': 4,
            'merged_from': found if len(found) > 1 else None,
            'bbox': bbox,
            'geometry': merged_geom
        })
        
        if len(found) > 1:
            print(f"  ✅ {new_name} (gộp từ: {', '.join(found)})")
        else:
            print(f"  ✅ {new_name}")
    
    # Xử lý các tỉnh còn lại chưa có trong danh sách
    for name, geom in province_map.items():
        if name not in processed:
            bbox = calculate_bbox(geom)
            features.append({
                'name': name,
                'type': 'province',
                'admin_level': 4,
                'bbox': bbox,
                'geometry': geom
            })
            print(f"  ➕ {name} (giữ nguyên)")
    
    # Đếm số tỉnh (trừ country)
    province_count = len([f for f in features if f.get('type') == 'province'])
    
    # Tạo output
    output = {
        "version": "2.1",
        "generated": datetime.now().strftime("%Y-%m-%d"),
        "source": "GADM 4.1 (simplified/smoothed) - Dissolved",
        "note": f"{province_count} đơn vị hành chính - Quy hoạch 2025 (Đã xóa biên giới trong)",
        "total": len(features),
        "features": features
    }
    
    # Lưu file
    with open('vn_boundaries_2025.json', 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False)
    
    print(f"\n✓ Đã tạo {len(features)} ranh giới ({province_count} tỉnh/thành)")
    print("  File: vn_boundaries_2025.json")

if __name__ == "__main__":
    print("Tạo dữ liệu ranh giới 2025 từ GADM smoothed")
    print("=" * 50)
    create_2025_boundaries()
