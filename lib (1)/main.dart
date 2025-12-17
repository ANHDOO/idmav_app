import 'package:flutter/material.dart';
import 'login_page.dart';
import 'home_page.dart';
import 'splash_page.dart'; // <--- Import trang Splash mới tạo

void main() {
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
        '/home': (context) => const HomePage(),
      },
    );
  }
}