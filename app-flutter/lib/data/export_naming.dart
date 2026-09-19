import 'dart:io';

import 'package:share_plus/share_plus.dart';

/// 내보내기 파일 이름. 확장자는 호출부가 붙인다.
///
/// ★ 예전에는 session_id 앞 8자를 썼는데(trip_79a1dc32), 카톡 대화방에
///   받아보면 그게 뭔지 알 수 없었다. 시작 시각을 쓰면 파일 목록에서
///   바로 구분된다.
String exportBaseName(int startedAtMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
  String two(int n) => n.toString().padLeft(2, '0');
  return 'trip_${d.year}-${two(d.month)}-${two(d.day)}_'
      '${two(d.hour)}${two(d.minute)}';
}

/// 내보내기 파일을 공유 시트로 넘긴다. CSV/GPX가 공유하는 유일한 경로.
///
/// ★ text와 subject를 절대 넘기지 않는다.
///   share_plus는 파일을 EXTRA_STREAM에 담은 뒤, text가 있으면 EXTRA_TEXT를,
///   subject가 있으면 EXTRA_SUBJECT를 같은 인텐트에 얹는다 (Share.kt shareFiles).
///   카카오톡은 이때 문자열만 취하고 첨부를 조용히 버린다. 실제로
///   '자전거 궤적 로그 - session 79a1dc32...' 한 줄만 전송되고 좌표는
///   하나도 가지 않았다. 파일이 무엇인지는 파일명으로 충분히 알 수 있다.
///
/// ★ mimeType을 명시한다. 없으면 */* 로 나가서 수신 앱이 처리를 거를 수 있다.
Future<void> shareExportFile(File file, String mimeType) async {
  await Share.shareXFiles([XFile(file.path, mimeType: mimeType)]);
}
