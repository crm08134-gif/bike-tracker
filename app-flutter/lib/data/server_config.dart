import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

/// 서버 주소 설정. `device_id`와 같은 SharedPreferences에 둔다.
///
/// ★ 저장된 값이 없으면 빌드 때 정한 [K.defaultApiBaseUrl]을 쓴다. 설정을
///   건드리지 않은 USB(adb reverse) 빌드는 예전과 똑같이 동작한다.
///
/// ★ SharedPreferences 캐시는 isolate마다 따로 있다. UI가 저장한 값을 서비스
///   isolate에서 읽으려면 [load]에 `reload: true`를 준다. 수집 중에 바뀐 값은
///   reload로 못 받으므로 UI가 [K.evtSetServerUrl]로 따로 알린다.
class ServerConfig {
  ServerConfig._();

  /// 지금 적용되는 주소. 저장값이 없으면 기본값이다.
  static Future<String> load({bool reload = false}) async =>
      (await loadSaved(reload: reload)) ?? K.defaultApiBaseUrl;

  /// 사용자가 저장한 주소. 없으면 null (= 기본값 사용 중).
  static Future<String?> loadSaved({bool reload = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (reload) await prefs.reload();
    return prefs.getString(K.prefsServerBaseUrl);
  }

  /// [raw]를 검증·정규화해 저장하고, 저장한 주소를 돌려준다.
  /// 형식이 틀리면 [FormatException]을 던지고 아무것도 저장하지 않는다.
  static Future<String> save(String raw) async {
    final url = normalize(raw);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(K.prefsServerBaseUrl, url);
    return url;
  }

  /// 저장값을 지운다. 이후 [load]는 기본값을 돌려준다.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(K.prefsServerBaseUrl);
  }

  /// 형식 오류 메시지. 올바르면 null.
  static String? validate(String raw) {
    try {
      normalize(raw);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// `http://host:port` 모양으로 정규화한다. 끝의 `/`와 공백은 떼어 낸다.
  ///
  /// - http는 포트를 반드시 적는다. 서버가 8080이라 `http://192.168.0.10`처럼
  ///   포트를 빠뜨리면 80으로 가서 연결 테스트에서야 드러난다.
  /// - https는 포트를 생략할 수 있다 (나중에 443 뒤로 옮길 때).
  /// - 경로는 받지 않는다. API 경로(`/api/v1/...`)는 ApiClient가 붙인다.
  static String normalize(String raw) {
    var s = raw.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) throw const FormatException('주소를 입력하세요');

    final Uri uri;
    try {
      uri = Uri.parse(s);
    } on FormatException {
      throw const FormatException('주소 형식이 올바르지 않습니다');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('http:// 로 시작해야 합니다 (예: http://192.168.0.10:8080)');
    }
    if (uri.host.isEmpty) throw const FormatException('호스트가 없습니다');
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('사용자 정보(@)는 넣을 수 없습니다');
    }
    if (uri.path.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException('경로 없이 http://host:port 까지만 적어 주세요');
    }

    // Uri는 기본 포트(:80, :443)를 적어도 hasPort가 false다. 원문으로 판단한다.
    final explicitPort = RegExp(r'^[a-zA-Z]+://[^/?#]*:(\d+)$').firstMatch(s);
    if (explicitPort == null && uri.scheme == 'http') {
      throw const FormatException('포트를 적어 주세요 (예: http://192.168.0.10:8080)');
    }
    if (explicitPort != null) {
      final port = int.parse(explicitPort.group(1)!);
      if (port < 1 || port > 65535) {
        throw const FormatException('포트는 1~65535 사이여야 합니다');
      }
    }

    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final port = explicitPort == null ? '' : ':${uri.port}';
    return '${uri.scheme}://$host$port';
  }
}
