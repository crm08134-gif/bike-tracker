import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'service/background_service.dart';
import 'state/tracking_controller.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // user_id를 최초 1회 생성해 영구 저장
  await TrackingController.ensureUserId();

  // 알림 채널 생성 + 백그라운드 서비스 설정 (autoStart: false)
  await initializeBackgroundService();

  runApp(const ProviderScope(child: MyGpsTrackerApp()));
}

class MyGpsTrackerApp extends StatelessWidget {
  const MyGpsTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My GPS Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: HomeScreen(),
    );
  }
}
