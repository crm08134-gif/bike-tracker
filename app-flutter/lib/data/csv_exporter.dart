import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_db.dart';
import 'export_naming.dart';

/// 세션 로그를 CSV로 내보낸다.
///
/// ★ raw ts를 가공 없이 그대로 기록한다.
///   Android가 위치를 배칭해서 몰아주는지 확인하려면
///   원본 타임스탬프 간격 분포를 봐야 하기 때문이다.
class CsvExporter {
  static const _header = 'session_id,ts,lat,lng,acc,spd,alt,label\n';
  static const _chunk = 2000;

  static Future<File> export(
    String sessionId, {
    required int startedAt,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '${exportBaseName(startedAt)}.csv'));
    final sink = file.openWrite();
    sink.write(_header);

    var offset = 0;
    while (true) {
      final rows =
          await AppDb.readPointsChunk(sessionId, limit: _chunk, offset: offset);
      if (rows.isEmpty) break;
      for (final r in rows) {
        sink.write([
          r['session_id'],
          r['ts'],
          r['lat'],
          r['lng'],
          r['acc'] ?? '',
          r['spd'] ?? '',
          r['alt'] ?? '',
          r['label'],
        ].join(','));
        sink.write('\n');
      }
      offset += rows.length;
      if (rows.length < _chunk) break;
    }

    await sink.flush();
    await sink.close();
    return file;
  }

  static Future<void> exportAndShare(
    String sessionId, {
    required int startedAt,
  }) async {
    final file = await export(sessionId, startedAt: startedAt);
    // ★ 'text/csv'를 쓰면 안 된다.
    //   카카오톡은 CSV와 GPX를 같은 액티비티로 받지만, 그 안에서 MIME이
    //   text/* 인지로 처리 경로를 가른다. text/csv는 '텍스트 전송' 경로로
    //   들어가 EXTRA_TEXT를 찾는데, 첨부가 버려지는 문제 때문에 우리가
    //   EXTRA_TEXT를 빼놨으므로 보낼 내용이 없어 아무 일도 일어나지 않는다.
    //   (실측: 같은 코드에서 application/gpx+xml인 GPX는 파일이 정상 전송됨)
    //   확장자가 .csv라 받는 쪽에서 엑셀로 여는 데는 지장이 없다.
    await shareExportFile(file, 'application/octet-stream');
  }
}
