import requests
import json
import os

# Sử dụng server maps.mail.ru (nhanh và ổn định như online search)
OVERPASS_URL = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"

def download_roads():
    # Query mở rộng: Thêm secondary, tertiary và tất cả đường có ref/name
    query = """
    [out:json][timeout:600];
    area["ISO3166-1"="VN"]->.searchArea;
    (
      // Đường chính: motorway, trunk, primary, secondary
      way["highway"~"^(motorway|trunk|primary|secondary)$"](area.searchArea);
      // Đường có mã số (QL, TL, ĐT...) - bất kể loại
      way["highway"]["ref"](area.searchArea);
    );
    out geom;
    """
    
    print("⏳ Đang tải dữ liệu đường bộ từ Overpass API (motorway, trunk, primary)...")
    print("   (Việc này có thể mất vài phút tùy thuộc vào tốc độ mạng và server)")
    
    try:
        response = requests.get(OVERPASS_URL, params={'data': query})
        response.raise_for_status()
        
        data = response.json()
        
        # Lưu file
        output_file = 'vn_roads.json'
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False)
            
        element_count = len(data.get('elements', []))
        print(f"\n✅ Đã tải xong {element_count} đoạn đường!")
        print(f"   File: {os.path.abspath(output_file)}")
        
    except Exception as e:
        print(f"\n❌ Lỗi khi tải dữ liệu: {e}")

if __name__ == "__main__":
    download_roads()
