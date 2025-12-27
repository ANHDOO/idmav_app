import 'package:flutter/material.dart';
import 'login_page.dart';
import 'home_page.dart';
import 'main_navigation.dart'; // <--- Import MainNavigation
import 'splash_page.dart'; // <--- Import trang Splash mới tạo
import 'services/offline_map_service.dart'; // <--- Import Offline Map Service

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Khởi tạo FMTC cho bản đồ offline
  await OfflineMapService().initialize();
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'iDMAV 5.0',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      // --- QUAN TRỌNG: Đặt trang khởi động là SplashPage ---
      home: const SplashPage(), 
      // -----------------------------------------------------
      
      // Định nghĩa các đường dẫn
      routes: {
        '/login': (context) => const LoginPage(),
        '/home': (context) => const MainNavigation(), // <--- Đổi từ HomePage sang MainNavigation
      },
    );
  }
}
