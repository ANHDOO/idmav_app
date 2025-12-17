import requests
import json
import time
import os
import concurrent.futures
from math import floor, ceil

# --- CẤU HÌNH ---
OUTPUT_FILE = 'assets/roads/vn_roads_full.json'
TEMP_DIR = 'assets/roads/temp_chunks'

# Phạm vi Việt Nam (mở rộng)
VN_BOUNDS = (8.0, 102.0, 24.0, 110.0) # min_lat, min_lon, max_lat, max_lon
GRID_SIZE = 0.5 # Kích thước ô lưới (độ). 0.5x0.5 độ là an toàn để tránh timeout

# Loại đường cần tải
# Chi tiết nhất: bao gồm cả residential, unclassified, service...
# Lưu ý: service và track có thể rất nhiều, cân nhắc bỏ nếu quá nặng
ROAD_TYPES = [
    "motorway", "trunk", "primary", "secondary", "tertiary"
    # Đã loại bỏ xxx_link để chỉ giữ lại trục đường chính, tránh đường nhánh rườm rà
]
ROAD_TYPES_STR = "|".join(ROAD_TYPES)

# Danh sách server Overpass (để load balancing)
SERVERS = [
    "https://overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
]

# Số luồng tải song song (đừng để quá cao kẻo bị ban IP)
MAX_WORKERS = 10 

# --- HÀM HỖ TRỢ ---

def ensure_dir(directory):
    if not os.path.exists(directory):
        os.makedirs(directory)

def get_bbox_str(lat, lon, size):
    return f"{lat},{lon},{lat+size},{lon+size}"

def fetch_tile(lat, lon, size, server_index):
    bbox = get_bbox_str(lat, lon, size)
    
    # Thêm bộ lọc area["ISO3166-1"="VN"] để chỉ lấy đường trong lãnh thổ Việt Nam
    # Kết hợp với bounding box của ô lưới hiện tại
    query = f"""
    [out:json][timeout:180];
    area["ISO3166-1"="VN"]->.searchArea;
    (
      way["highway"~"^({ROAD_TYPES_STR})$"](area.searchArea)({bbox});
    );
    out geom;
    """
    
    server = SERVERS[server_index % len(SERVERS)]
    try:
        response = requests.post(server, data={'data': query}, timeout=200)
        if response.status_code == 200:
            return response.json()
        elif response.status_code == 429: # Too Many Requests
            time.sleep(5)
            return fetch_tile(lat, lon, size, server_index + 1) # Retry with different server
        else:
            print(f"Error {response.status_code} fetching {bbox} from {server}")
            return None
    except Exception as e:
        print(f"Exception fetching {bbox}: {e}")
        return None

def process_elements(elements):
    """Chuyển đổi dữ liệu raw từ Overpass sang cấu trúc trung gian"""
    processed = {} # key: (name, ref, type) -> list of segments
    
    for el in elements:
        tags = el.get('tags', {})
        highway = tags.get('highway', '')
        name = tags.get('name', '')
        ref = tags.get('ref', '')
        
        # Bỏ qua đường không có tên VÀ không có ref (để giảm dung lượng rác)
        # Nếu muốn chi tiết tuyệt đối (chấp nhận đường vô danh), comment dòng dưới
        if not name and not ref:
            continue
            
        geometry = el.get('geometry', [])
        if not geometry: continue
        
        # Convert geometry to list of [lon, lat]
        coords = [[p['lon'], p['lat']] for p in geometry]
        
        # Key để gom nhóm các đoạn đường cùng tên
        key = (name, ref, highway)
        
        if key not in processed:
            processed[key] = []
        processed[key].append(coords)
        
    return processed

def merge_processed_data(main_dict, new_dict):
    for key, segments in new_dict.items():
        if key not in main_dict:
            main_dict[key] = []
        main_dict[key].extend(segments)

def calculate_feature_bbox(segments):
    min_lat, min_lon = 90.0, 180.0
    max_lat, max_lon = -90.0, -180.0
    for seg in segments:
        for p in seg:
            lon, lat = p
            if lat < min_lat: min_lat = lat
            if lat > max_lat: max_lat = lat
            if lon < min_lon: min_lon = lon
            if lon > max_lon: max_lon = lon
    return [min_lat, min_lon, max_lat, max_lon]

# --- MAIN ---

def main():
    print("=== TOOL TẢI DỮ LIỆU ĐƯỜNG VIỆT NAM FULL (Multithreaded) ===")
    ensure_dir(os.path.dirname(OUTPUT_FILE))
    ensure_dir(TEMP_DIR)
    
    # Tạo danh sách các ô lưới (Tiles)
    tasks = []
    lat = VN_BOUNDS[0]
    idx = 0
    while lat < VN_BOUNDS[2]:
        lon = VN_BOUNDS[1]
        while lon < VN_BOUNDS[3]:
            tasks.append((lat, lon, idx))
            lon += GRID_SIZE
            idx += 1
        lat += GRID_SIZE
        
    print(f"Tổng số ô lưới cần tải: {len(tasks)}")
    
    # Dictionary toàn cục để lưu kết quả (Key: (name, ref, type))
    # Lưu ý: Với dữ liệu full VN, dict này có thể rất lớn RAM. 
    # Nếu RAM không đủ, cần lưu temp file rồi merge sau. 
    # Ở đây giả định PC có đủ RAM (>4GB free).
    global_data = {} 
    
    completed = 0
    start_time = time.time()
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_tile = {
            executor.submit(fetch_tile, t[0], t[1], GRID_SIZE, t[2]): t 
            for t in tasks
        }
        
        for future in concurrent.futures.as_completed(future_to_tile):
            lat, lon, _ = future_to_tile[future]
            completed += 1
            data = future.result()
            
            if data and 'elements' in data:
                elements = data['elements']
                chunk_data = process_elements(elements)
                merge_processed_data(global_data, chunk_data)
                
                # Feedback
                elapsed = time.time() - start_time
                print(f"[{completed}/{len(tasks)}] Xong ô {lat},{lon}. "
                      f"Tìm thấy: {len(chunk_data)} con đường mới trong ô. "
                      f"Tổng đường (đã gộp): {len(global_data)}. "
                      f"Thời gian: {elapsed:.1f}s")
            else:
                print(f"[{completed}/{len(tasks)}] ❌ Lỗi hoặc rỗng ô {lat},{lon}")

    # Chuyển đổi sang format JSON đích
    print("\nĐang gộp và tạo file JSON cuối cùng...")
    final_features = []
    
    for (name, ref, road_type), segments in global_data.items():
        bbox = calculate_feature_bbox(segments)
        feature = {
            "name": name,
            "ref": ref,
            "road_type": road_type,
            "bbox": bbox,
            "geometry": {
                "type": "MultiLineString",
                "coordinates": segments
            }
        }
        final_features.append(feature)
        
    # Tạo output object
    output = {
        "version": "1.0",
        "generated": time.strftime("%Y-%m-%d"),
        "source": "OpenStreetMap Overpass (Full Detail)",
        "total": len(final_features),
        "features": final_features
    }
    
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
        
    print(f"\n✅ HOÀN TẤT! Đã lưu {len(final_features)} con đường vào {OUTPUT_FILE}")
    print(f"File size: {os.path.getsize(OUTPUT_FILE) / (1024*1024):.2f} MB")

if __name__ == '__main__':
    # Kiểm tra requests
    try:
        import requests
        main()
    except ImportError:
        print("Lỗi: Chưa cài thư viện 'requests'.")
        print("Vui lòng chạy: pip install requests")
