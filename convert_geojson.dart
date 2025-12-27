import 'dart:convert';
import 'dart:io';
import 'dart:math';

void main() async {
  final File inputFile = File('assets/roads/TEST/export.geojson');
  final File outputFile = File('assets/roads/TEST/vn_roads_converted.json');

  if (!await inputFile.exists()) {
    print('Error: Input file not found: ${inputFile.path}');
    return;
  }

  print('Reading ${inputFile.path}...');
  String content = await inputFile.readAsString();
  Map<String, dynamic> data = jsonDecode(content);

  List<dynamic> originalFeatures = data['features'];
  List<Map<String, dynamic>> convertedFeatures = [];

  print('Processing ${originalFeatures.length} features...');

  int count = 0;
  for (var f in originalFeatures) {
    Map<String, dynamic> feature = f as Map<String, dynamic>;
    Map<String, dynamic> properties = feature['properties'] ?? {};
    Map<String, dynamic> geometry = feature['geometry'];

    // 1. Map properties
    String name = properties['name'] ?? '';
    String ref = properties['ref'] ?? '';
    String highway = properties['highway'] ?? '';

    // Map highway -> road_type
    String roadType = highway; // 1:1 mapping mostly matches our app logic
    
    // 2. Calculate BBOx
    List<double> bbox = _calculateBbox(geometry);

    // 3. Create new flattened feature structure
    Map<String, dynamic> newFeature = {
      'type': 'Feature',
      'name': name,
      'ref': ref,
      'road_type': roadType,
      'bbox': bbox,
      'geometry': geometry, // Keep geometry as is
    };

    convertedFeatures.add(newFeature);
    count++;
  }

  Map<String, dynamic> outputData = {
    'type': 'FeatureCollection',
    'features': convertedFeatures,
  };

  print('Writing to ${outputFile.path}...');
  await outputFile.writeAsString(jsonEncode(outputData));
  print('Done! Converted $count features.');
}

List<double> _calculateBbox(Map<String, dynamic> geometry) {
  String type = geometry['type'];
  List<dynamic> coords = geometry['coordinates'];
  
  double minLng = 180.0;
  double maxLng = -180.0;
  double minLat = 90.0;
  double maxLat = -90.0;

  void processPoint(List<dynamic> pt) {
    double lng = (pt[0] as num).toDouble();
    double lat = (pt[1] as num).toDouble();
    minLng = min(minLng, lng);
    maxLng = max(maxLng, lng);
    minLat = min(minLat, lat);
    maxLat = max(maxLat, lat);
  }

  if (type == 'LineString') {
    for (var pt in coords) {
      processPoint(pt as List);
    }
  } else if (type == 'MultiLineString') {
    for (var line in coords) {
      for (var pt in line) {
        processPoint(pt as List);
      }
    }
  }

  // format: [south, west, north, east] -> [minLat, minLng, maxLat, maxLng]
  return [minLat, minLng, maxLat, maxLng];
}
