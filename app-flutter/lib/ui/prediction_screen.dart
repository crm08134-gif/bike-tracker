import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../data/api_client.dart';
import '../../data/app_db.dart';
import '../../data/prediction.dart';
import '../../data/server_config.dart';
import 'label_colors.dart';

/// 주행이 끝난 뒤 보는 서버 판정 결과. **실시간이 아니다.**
///
/// ★ 캐시 정책
///   - 열면 항상 로컬 캐시를 보여준다.
///   - 서버는 새로고침을 눌렀을 때와, 캐시가 없는 최초 진입에서만 부른다.
///   - 주기적 폴링·백그라운드 갱신은 없다.
///
/// ★ 세션 목록에서만 들어온다 = 수집이 정지된 상태다. 그래서 UI isolate가 캐시를 써도
///   서비스 isolate와 동시 쓰기가 나지 않는다 (AppDb 접근 규칙).
class PredictionScreen extends StatefulWidget {
  const PredictionScreen({super.key, required this.session});

  final SessionSummary session;

  @override
  State<PredictionScreen> createState() => _PredictionScreenState();
}

class _PredictionScreenState extends State<PredictionScreen> {
  /// 첫 조회 때 만든다. 주소는 조회할 때마다 설정에서 다시 읽는다 ([_fetch]).
  ApiClient? _api;

  bool _loadingLocal = true;
  bool _fetching = false;
  PredictionSnapshot? _snap;
  Map<String, int> _batches = const {};

  /// 마지막 조회 실패. 캐시가 있으면 캐시를 그대로 두고 이것만 알린다.
  UploadFailure? _error;

  String get _sid => widget.session.sessionId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _api?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final batches = await AppDb.countBatchesByState(_sid);
    final snap = await AppDb.loadPredictions(_sid);
    if (!mounted) return;
    setState(() {
      _batches = batches;
      _snap = snap;
      _loadingLocal = false;
    });
    if (snap == null) await _fetch();
  }

  Future<void> _fetch() async {
    if (_fetching) return;
    setState(() => _fetching = true);
    try {
      // ★ 전송(서비스 isolate)과 같은 설정값을 쓴다. 설정 화면에서 바꾼 주소가
      //   화면을 다시 열지 않아도 다음 새로고침부터 적용된다.
      final baseUrl = await ServerConfig.load();
      final api = _api ??= ApiClient(baseUrl: baseUrl);
      api.baseUrl = baseUrl;
      final snap = await api.fetchPredictions(_sid);
      await AppDb.replacePredictions(snap);
      // 전송 상태도 폰 DB에서 다시 읽는다. 서버는 부르지 않는다.
      final batches = await AppDb.countBatchesByState(_sid);
      if (!mounted) return;
      setState(() {
        _snap = snap;
        _batches = batches;
        _error = null;
      });
    } on UploadFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      if (_snap != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('조회 실패: ${_errorText(e)}')));
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  static String _errorText(UploadFailure e) {
    if (e.code == 'SESSION_NOT_FOUND') return '서버에 이 세션이 아직 없습니다';
    if (e.status == null) return '서버에 연결하지 못했습니다';
    return '${e.code} (${e.status})';
  }

  static String _fmtDateTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _fmtClock(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String _fmtDuration(int ms) {
    final sec = ms ~/ 1000;
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
    if (h > 0) return '$h시간 $m분';
    if (m > 0) return '$m분 $s초';
    return '$s초';
  }

  static String _serverStateKorean(String s) {
    switch (s) {
      case RemoteSessionState.active:
        return '수신 중';
      case RemoteSessionState.closed:
        return '종료됨';
      case RemoteSessionState.abandoned:
        return '중단됨 (응답 없음)';
      default:
        return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('주행 판정'),
        actions: [
          _fetching
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '새로고침',
                  onPressed: _loadingLocal ? null : _fetch,
                ),
        ],
      ),
      body: _loadingLocal
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${_fmtDateTime(widget.session.startedAt)} · '
                  '${_sid.substring(0, 8)}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                const SizedBox(height: 12),
                ..._uploadCards(),
                ..._body(),
              ],
            ),
    );
  }

  /// 폰 `batches` 상태로만 판단한다.
  List<Widget> _uploadCards() {
    final unsent = (_batches[BatchState.pending] ?? 0) +
        (_batches[BatchState.failed] ?? 0);
    final dead = _batches[BatchState.dead] ?? 0;
    return [
      if (unsent > 0)
        _notice(
          color: Colors.amber.shade50,
          icon: Icons.cloud_upload_outlined,
          title: '미전송 $unsent건',
          text: '서버로 보내지 않은 배치 $unsent개가 폰에 남아 있습니다. '
              '홈 화면의 [서버로 보내기]로 전송한 뒤 이 화면을 새로고침하세요. '
              '아래 결과에는 아직 이 좌표가 빠져 있습니다.',
        ),
      if (dead > 0)
        _notice(
          color: Colors.red.shade50,
          icon: Icons.block,
          title: '전송 거부',
          text: '서버가 받지 않은 배치 $dead개가 있습니다. 다시 보내지 않습니다.',
        ),
    ];
  }

  List<Widget> _body() {
    final snap = _snap;
    if (snap == null) {
      if (_fetching) {
        return const [
          SizedBox(height: 48),
          Center(child: CircularProgressIndicator()),
        ];
      }
      return [
        _notice(
          color: Colors.grey.shade100,
          icon: Icons.cloud_off,
          title: '판정 결과 없음',
          text: _error == null
              ? '아직 조회하지 않았습니다.'
              : '${_errorText(_error!)}. 새로고침으로 다시 조회할 수 있습니다.',
        ),
      ];
    }

    final runs = summarizeRuns(snap.points);
    final totals = totalDurationByLabel(runs);

    return [
      Row(children: [
        Icon(Icons.history, size: 16, color: Colors.grey.shade600),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '저장된 결과 · 마지막 조회 ${_fmtDateTime(snap.fetchedAt)}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      _progressCard(snap),
      const SizedBox(height: 12),
      _summaryCard(totals),
      const SizedBox(height: 12),
      _runsCard(runs),
    ];
  }

  Widget _progressCard(PredictionSnapshot snap) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('서버 세션: ${_serverStateKorean(snap.sessionState)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _metric('${snap.totalPoints}', '전체 좌표'),
                _metric('${snap.predictedPoints}', '판정됨'),
                _metric('${snap.unpredictablePoints}', '판정 불가'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '판정 불가: 200개 미만으로 끊긴 구간이라 판정할 수 없는 좌표',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            if (snap.waitingBatches > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '서버가 순서를 기다리는 배치 ${snap.waitingBatches}개가 있어 '
                  '전체 좌표 수가 늘어날 수 있습니다.',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(Map<String?, int> totals) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('판정 요약', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (totals.isEmpty)
              Text('서버에 저장된 좌표가 없습니다.',
                  style: TextStyle(color: Colors.grey.shade600))
            else
              ...totals.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      _labelDot(e.key),
                      const SizedBox(width: 8),
                      Expanded(child: Text(predictionLabelKorean(e.key))),
                      Text(_fmtDuration(e.value),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          )),
                    ]),
                  )),
          ],
        ),
      ),
    );
  }

  Widget _runsCard(List<PredictionRun> runs) {
    if (runs.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('구간별 판정', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ...runs.map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    _labelDot(r.label),
                    const SizedBox(width: 8),
                    Text(
                      '${_fmtClock(r.startTs)} – ${_fmtClock(r.endTs)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(predictionLabelKorean(r.label))),
                    Text(_fmtDuration(r.durationMs),
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade700)),
                  ]),
                )),
          ],
        ),
      ),
    );
  }

  Widget _labelDot(String? label) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
          color: predictionLabelColor(label), shape: BoxShape.circle),
    );
  }

  Widget _notice({
    required Color color,
    required IconData icon,
    required String title,
    required String text,
  }) {
    return Card(
      color: color,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(text, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String value, String label) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              )),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      );
}
