#!/usr/bin/env python3
"""
Convert GADM GeoJSON to vn_boundaries.json format
GADM 4.1 has 63 separate provinces (pre-merge data)
"""
import json
from datetime import datetime

# Name mapping từ GADM (không dấu, viết liền) sang tên chuẩn tiếng Việt
NAME_MAP = {
    'AnGiang': 'An Giang',
    'BàRịa-VũngTàu': 'Bà Rịa - Vũng Tàu',
    'BắcGiang': 'Bắc Giang',
    'BắcKạn': 'Bắc Kạn',
    'BạcLiêu': 'Bạc Liêu',
    'BắcNinh': 'Bắc Ninh',
    'BếnTre': 'Bến Tre',
    'BìnhĐịnh': 'Bình Định',
    'BìnhDương': 'Bình Dương',
    'BìnhPhước': 'Bình Phước',
    'BìnhThuận': 'Bình Thuận',
    'CàMau': 'Cà Mau',
    'CầnThơ': 'TP. Cần Thơ',
    'CaoBằng': 'Cao Bằng',
    'ĐàNẵng': 'TP. Đà Nẵng',
    'ĐắkLắk': 'Đắk Lắk',
    'ĐắkNông': 'Đắk Nông',
    'ĐiệnBiên': 'Điện Biên',
    'ĐồngNai': 'Đồng Nai',
    'ĐồngTháp': 'Đồng Tháp',
    'GiaLai': 'Gia Lai',
    'HàGiang': 'Hà Giang',
    'HảiDương': 'Hải Dương',
    'HảiPhòng': 'TP. Hải Phòng',
    'HàNam': 'Hà Nam',
    'HàNội': 'Thủ Đô Hà Nội',
    'HàTĩnh': 'Hà Tĩnh',
    'HậuGiang': 'Hậu Giang',
    'HồChíMinh': 'TP. Hồ Chí Minh',
    'HoàBình': 'Hòa Bình',
    'HưngYên': 'Hưng Yên',
    'KhánhHòa': 'Khánh Hòa',
    'KiênGiang': 'Kiên Giang',
    'KonTum': 'Kon Tum',
    'LaiChâu': 'Lai Châu',
    'LâmĐồng': 'Lâm Đồng',
    'LạngSơn': 'Lạng Sơn',
    'LàoCai': 'Lào Cai',
    'LongAn': 'Long An',
    'NamĐịnh': 'Nam Định',
    'NghệAn': 'Nghệ An',
    'NinhBình': 'Ninh Bình',
    'NinhThuận': 'Ninh Thuận',
    'PhúThọ': 'Phú Thọ',
    'PhúYên': 'Phú Yên',
    'QuảngBình': 'Quảng Bình',
    'QuảngNam': 'Quảng Nam',
    'QuảngNgãi': 'Quảng Ngãi',
    'QuảngNinh': 'Quảng Ninh',
    'QuảngTrị': 'Quảng Trị',
    'SócTrăng': 'Sóc Trăng',
    'SơnLa': 'Sơn La',
    'TâyNinh': 'Tây Ninh',
    'TháiBình': 'Thái Bình',
    'TháiNguyên': 'Thái Nguyên',
    'ThanhHóa': 'Thanh Hóa',
    'ThừaThiên-Huế': 'Thừa Thiên Huế',
    'ThừaThiênHuế': 'Thừa Thiên Huế',
    'TiềnGiang': 'Tiền Giang',
    'TràVinh': 'Trà Vinh',
    'TuyênQuang': 'Tuyên Quang',
    'VĩnhLong': 'Vĩnh Long',
    'VĩnhPhúc': 'Vĩnh Phúc',
    'YênBái': 'Yên Bái',
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
    
    return [min_lat, min_lng, max_lat, max_lng]

def convert_gadm():
    # Load GADM country data (quốc gia)
    with open('gadm_vietnam_country.json', 'r', encoding='utf-8') as f:
        country_data = json.load(f)
    
    # Load GADM provinces data (63 tỉnh/thành)
    with open('gadm_vietnam_provinces.json', 'r', encoding='utf-8') as f:
        gadm = json.load(f)
    
    features = []
    
    # Thêm dữ liệu quốc gia Việt Nam trước
    for feat in country_data.get('features', []):
        geometry = feat.get('geometry', {})
        bbox = calculate_bbox(geometry)
        
        features.append({
            'name': 'Việt Nam',
            'type': 'country',
            'admin_level': 2,
            'bbox': bbox,
            'geometry': geometry
        })
        print(f"  Vietnam (country) (bbox: {bbox[0]:.2f},{bbox[1]:.2f} - {bbox[2]:.2f},{bbox[3]:.2f})")
    
    # Thêm dữ liệu 63 tỉnh/thành
    for feat in gadm.get('features', []):
        props = feat.get('properties', {})
        gadm_name = props.get('NAME_1', '')
        
        # Map to Vietnamese name
        vn_name = NAME_MAP.get(gadm_name, gadm_name)
        
        geometry = feat.get('geometry', {})
        bbox = calculate_bbox(geometry)
        
        features.append({
            'name': vn_name,
            'type': 'province',
            'admin_level': 4,
            'gadm_id': props.get('GID_1', ''),
            'bbox': bbox,  # THÊM BBOX
            'geometry': geometry
        })
        
        print(f"  {gadm_name} → {vn_name} (bbox: {bbox[0]:.2f},{bbox[1]:.2f} - {bbox[2]:.2f},{bbox[3]:.2f})")
    
    # Create output
    output = {
        "version": "1.0",
        "generated": datetime.now().strftime("%Y-%m-%d"),
        "source": "GADM 4.1 (geodata.ucdavis.edu)",
        "note": "Dữ liệu 63 tỉnh/thành (trước sáp nhập)",
        "total": len(features),
        "features": features
    }
    
    # Save
    with open('vn_boundaries.json', 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    
    print(f"\n✓ Đã chuyển đổi {len(features)} tỉnh/thành")
    print("  File: vn_boundaries.json")

if __name__ == "__main__":
    print("Chuyển đổi GADM → vn_boundaries.json")
    print("=" * 50)
    convert_gadm()
