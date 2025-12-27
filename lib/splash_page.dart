import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Màu chủ đạo (Đồng bộ với app)
const Color primaryDark = Color(0xFF1A2980);
const Color primaryLight = Color(0xFF26D0CE);

class SplashPage extends StatefulWidget {
  const SplashPage({Key? key}) : super(key: key);

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();

    // 1. Cấu hình hiệu ứng Fade In (Hiện dần)
    _controller = AnimationController(
      duration: const Duration(seconds: 1), // Thời gian hiệu ứng 2s
      vsync: this,
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);

    _controller.forward();

    // 2. Kiểm tra đăng nhập và chuyển trang
    _checkLoginAndNavigate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _checkLoginAndNavigate() async {
    // Giả lập thời gian load (để người dùng kịp nhìn thấy Logo)
    await Future.delayed(const Duration(seconds: 2));

    // Kiểm tra xem user đã "Nhớ mật khẩu" chưa
    final prefs = await SharedPreferences.getInstance();
    final bool rememberMe = prefs.getBool('rememberMe') ?? false;
    final String? savedUser = prefs.getString('username');

    if (!mounted) return;

    if (rememberMe && savedUser != null && savedUser.isNotEmpty) {
      // Nếu đã nhớ -> Vào thẳng trang chủ
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      // Nếu chưa -> Vào trang đăng nhập
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Nền Gradient sang trọng
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryDark, primaryLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo với hiệu ứng hiện dần
            FadeTransition(
              opacity: _animation,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 20,
                      offset: Offset(0, 10),
                    )
                  ],
                ),
                child: Image.asset(
                  'assets/TP.png', // Logo của bạn
                  width: 100,
                  height: 100,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(Icons.apartment, size: 80, color: primaryDark);
                  },
                ),
              ),
            ),
            
            const SizedBox(height: 30),

            // Tên App
            FadeTransition(
              opacity: _animation,
              child: const Column(
                children: [
                  Text(
                    'iDMAV 5.0',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Hệ thống điều khiển trung tâm',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 60),

            // Vòng tròn Loading nhỏ bên dưới
            const CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 3,
            ),
          ],
        ),
      ),
    );
  }
}