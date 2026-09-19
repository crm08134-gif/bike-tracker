import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../data/app_db.dart';
import '../../data/csv_exporter.dart';
import '../../data/gpx_exporter.dart';
import 'prediction_screen.dart';
import 'track_map_screen.dart';

/// 저장된 세션 목록.
/// ★ 이 화면은 수집이 정지된 상태에서만 진입 가능하다 (HomeScreen에서 제어).
///   서비스 isolate와 UI isolate가 동시에 DB를 쓰지 않게 하기 위함이다.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<SessionSummary> _sessions = [];
  bool _loading = true;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // UI가 연 DB 핸들을 닫아 다음 서비스 시작 시 락 여지를 줄인다.
    AppDb.close();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await AppDb.listSessions();
    if (mounted) setState(() {
          _sessions = s;
          _loading = false;
        });
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _share(SessionSummary s, String fmt) async {
    setState(() => _busy = s.sessionId);
    try {
      if (fmt == 'gpx') {
        await GpxExporter.exportAndShare(s.sessionId, startedAt: s.startedAt);
      } else {
        await CsvExporter.exportAndShare(s.sessionId, startedAt: s.startedAt);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _dur(SessionSummary s) {
    if (s.endedAt == null) return '진행 중 / 비정상 종료';
    final sec = (s.endedAt! - s.startedAt) ~/ 1000;
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, ss = sec % 60;
    return h > 0 ? '$h시간 $m분' : (m > 0 ? '$m분 $ss초' : '$ss초');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('세션 목록')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(child: Text('저장된 세션이 없습니다.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _sessions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = _sessions[i];
                      final busy = _busy == s.sessionId;
                      return ListTile(
                        title: Text(_fmt(s.startedAt)),
                        subtitle: Text(
                          '${s.pointCount} 포인트 · ${_dur(s)}\n'
                          '${s.sessionId.substring(0, 8)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        isThreeLine: true,
                        trailing: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // ★ 판정 상태를 목록에 표시하지 않고, 목록을 그릴 때
                                  //   서버를 부르지 않는다. 조회는 들어간 화면에서만 한다.
                                  // ★ 추적 중인 세션은 숨겨야 하는데, 이 화면 자체가 수집이
                                  //   정지된 상태에서만 열리므로(HomeScreen) 여기 오는 세션은
                                  //   전부 종료된 세션이다. 비정상 종료·전송 미완도 연다.
                                  IconButton(
                                    icon: const Icon(Icons.fact_check_outlined),
                                    tooltip: '주행 판정 조회',
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            PredictionScreen(session: s),
                                      ),
                                    ),
                                  ),
                                  // 앱 안 지도. 서버를 부르지 않고 폰 좌표와 저장된
                                  // 판정 캐시만 읽는다. 진입 조건은 판정 조회와 같다.
                                  IconButton(
                                    icon: const Icon(Icons.map_outlined),
                                    tooltip: '주행 기록 조회',
                                    onPressed: s.pointCount == 0
                                        ? null
                                        : () => Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    TrackMapScreen(session: s),
                                              ),
                                            ),
                                  ),
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.ios_share),
                                    tooltip: '내보내기',
                                    enabled: s.pointCount != 0,
                                    onSelected: (fmt) => _share(s, fmt),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'csv',
                                        child: Text('CSV · 원본 분석용'),
                                      ),
                                      PopupMenuItem(
                                        value: 'gpx',
                                        child: Text('GPX · 지도에서 열기'),
                                      ),
                                    ],
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: '삭제',
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (_) => AlertDialog(
                                          title: const Text('세션 삭제'),
                                          content: Text(
                                              '${s.pointCount}개 포인트가 삭제됩니다.'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, false),
                                                child: const Text('취소')),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(
                                                    context, true),
                                                child: const Text('삭제')),
                                          ],
                                        ),
                                      );
                                      if (ok == true) {
                                        await AppDb.deleteSession(s.sessionId);
                                        await _load();
                                      }
                                    },
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
    );
  }
}
