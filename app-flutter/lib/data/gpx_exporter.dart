import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import 'app_db.dart';
import 'export_naming.dart';

/// 세션 로그를 GPX 1.1로 내보낸다.
///
/// ★ CSV를 대체하는 게 아니라 보완한다.
///   - CSV: 원본 ts/acc를 그대로 담는 분석용. 배칭 간격 분포를 보려면 이쪽.
///   - GPX: 지도 앱·구글 어스에서 바로 선으로 그려보는 확인용.
///
/// ★ 라벨이 바뀌는 지점에서 <trkseg>를 끊는다.
///   그래야 구간이 지도에서 분리되어 보인다.
class GpxExporter {
  static const _chunk = 2000;

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// GPX의 <time>은 UTC ISO-8601이어야 한다. 로컬 시각을 쓰면 안 된다.
  static String _iso(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
          .toIso8601String()
          .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

  static void _wpt(IOSink sink, Map<String, Object?> r, String name) {
    sink.write('  <wpt lat="${r['lat']}" lon="${r['lng']}">\n');
    if (r['alt'] != null) sink.write('    <ele>${r['alt']}</ele>\n');
    sink.write('    <time>${_iso(r['ts'] as int)}</time>\n');
    sink.write('    <name>${_esc(name)}</name>\n');
    sink.write('  </wpt>\n');
  }

  static void _trkpt(IOSink sink, Map<String, Object?> r) {
    sink.write('      <trkpt lat="${r['lat']}" lon="${r['lng']}">\n');
    if (r['alt'] != null) sink.write('        <ele>${r['alt']}</ele>\n');
    sink.write('        <time>${_iso(r['ts'] as int)}</time>\n');
    sink.write('      </trkpt>\n');
  }

  static Future<File> export(
    String sessionId, {
    required int startedAt,
  }) async {
    final name = exportBaseName(startedAt);
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '$name.gpx'));
    final sink = file.openWrite();

    sink.write('<?xml version="1.0" encoding="UTF-8"?>\n');
    sink.write('<gpx version="1.1" creator="my_gps_tracker" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n');
    sink.write('  <metadata>\n'
        '    <name>${_esc(name)}</name>\n'
        '    <time>${_iso(startedAt)}</time>\n'
        '  </metadata>\n');

    // ★ GPX 1.1 스키마는 자식 순서가 강제된다:
    //     metadata -> wpt* -> rte* -> trk* -> extensions
    //   출발/도착 wpt를 trk 뒤에 쓰면 스키마 위반이라 엄격한 파서
    //   (구글 어스 등)가 파일을 통째로 거부한다. 그래서 트랙을 흘려 쓰기 전에
    //   첫/마지막 포인트만 따로 집어와 wpt를 먼저 쓴다.
    //   points(session_id, ts) 인덱스가 있어 두 번의 추가 조회는 사실상 공짜다.
    final total = await AppDb.countPoints(sessionId);
    if (total > 0) {
      final firstRows =
          await AppDb.readPointsChunk(sessionId, limit: 1, offset: 0);
      final lastRows =
          await AppDb.readPointsChunk(sessionId, limit: 1, offset: total - 1);
      if (firstRows.isNotEmpty) _wpt(sink, firstRows.first, '출발');
      if (lastRows.isNotEmpty) _wpt(sink, lastRows.first, '도착');
    }

    sink.write('  <trk>\n    <name>${_esc(name)}</name>\n');

    String? segLabel;
    var open = false;
    var offset = 0;

    while (true) {
      final rows =
          await AppDb.readPointsChunk(sessionId, limit: _chunk, offset: offset);
      if (rows.isEmpty) break;
      for (final r in rows) {
        final label = r['label'] as String? ?? TripLabel.none;
        if (!open || label != segLabel) {
          if (open) sink.write('    </trkseg>\n');
          // 라벨은 GPX 표준 필드가 아니다. 표준 파서는 주석을 무시하고,
          // 사람이 열어보면 구간 구분이 보인다.
          sink.write('    <!-- ${TripLabel.korean(label)} -->\n');
          sink.write('    <trkseg>\n');
          segLabel = label;
          open = true;
        }
        _trkpt(sink, r);
      }
      offset += rows.length;
      if (rows.length < _chunk) break;
    }

    if (open) sink.write('    </trkseg>\n');
    sink.write('  </trk>\n');
    sink.write('</gpx>\n');

    await sink.flush();
    await sink.close();
    return file;
  }

  static Future<void> exportAndShare(
    String sessionId, {
    required int startedAt,
  }) async {
    final file = await export(sessionId, startedAt: startedAt);
    await shareExportFile(file, 'application/gpx+xml');
  }
}
