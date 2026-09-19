import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// 권한 점검 결과. UI가 "무엇이 빠졌는지"를 그대로 보여준다.
class PermissionStatusReport {
  final bool locationServiceOn;
  final bool fineLocation;
  final bool notification;
  final bool backgroundLocation;
  final bool batteryUnrestricted;

  const PermissionStatusReport({
    required this.locationServiceOn,
    required this.fineLocation,
    required this.notification,
    required this.backgroundLocation,
    required this.batteryUnrestricted,
  });

  /// 배터리 최적화 예외는 "권장"이지 "필수"가 아니다.
  /// 없어도 동작은 하지만 장시간 수집에서 죽을 확률이 크게 올라간다.
  bool get canStart =>
      locationServiceOn && fineLocation && notification && backgroundLocation;

  List<String> get missing {
    final m = <String>[];
    if (!locationServiceOn) m.add('기기 위치(GPS) 켜기');
    if (!fineLocation) m.add('정밀 위치 권한');
    if (!notification) m.add('알림 권한');
    if (!backgroundLocation) m.add('위치 "항상 허용"');
    if (!batteryUnrestricted) m.add('배터리 최적화 예외 (권장)');
    return m;
  }
}

class PermissionManager {
  static Future<PermissionStatusReport> check() async {
    return PermissionStatusReport(
      locationServiceOn: await Geolocator.isLocationServiceEnabled(),
      fineLocation: await Permission.location.isGranted,
      notification: await Permission.notification.isGranted,
      backgroundLocation: await Permission.locationAlways.isGranted,
      batteryUnrestricted:
          await Permission.ignoreBatteryOptimizations.isGranted,
    );
  }

  /// 1) 기기 위치 서비스
  static Future<bool> ensureLocationService() async {
    if (await Geolocator.isLocationServiceEnabled()) return true;
    await Geolocator.openLocationSettings();
    return Geolocator.isLocationServiceEnabled();
  }

  /// 2) 앱 사용 중 정밀 위치
  /// ★ 이 단계가 먼저 승인되어야만 4)의 백그라운드 위치를 요청할 수 있다.
  static Future<bool> requestFineLocation() async {
    final s = await Permission.location.request();
    return s.isGranted;
  }

  /// 3) 알림 (Android 13+)
  static Future<bool> requestNotification() async {
    final s = await Permission.notification.request();
    return s.isGranted;
  }

  /// 4) 백그라운드 위치 ("항상 허용")
  ///
  /// ★ Android 11+ 에서는 시스템 다이얼로그로 즉시 받을 수 없다.
  ///   request()가 설정 화면으로 보내거나, 조용히 denied를 반환한다.
  ///   따라서 UI에서 반드시 사전 안내를 띄운 뒤 호출하고,
  ///   실패하면 openAppSettings()로 유도해야 한다.
  static Future<bool> requestBackgroundLocation() async {
    if (!await Permission.location.isGranted) return false;
    final s = await Permission.locationAlways.request();
    return s.isGranted;
  }

  /// 5) 배터리 최적화 예외 (권장)
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    final s = await Permission.ignoreBatteryOptimizations.request();
    return s.isGranted;
  }

  static Future<void> openSettings() => openAppSettings();
}
