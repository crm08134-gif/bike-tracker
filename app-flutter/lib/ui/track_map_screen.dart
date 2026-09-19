import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../core/constants.dart';
import '../../data/app_db.dart';
import '../../data/track.dart';
import 'label_colors.dart';

/// 세션 궤적을 앱 안 지도에 그린다.
///
/// ★ 우리 서버를 부르지 않는다. 좌표는 폰 `points`, 색은 주행 판정 화면이 저장해 둔
///   판정 캐시(`prediction_*`)만 읽는다. 캐시가 없으면 단색으로 그리고 안내만 한다.
///   네트워크는 OSM 지도 타일에만 쓴다 - 타일이 안 떠도 궤적은 그려진다.
///
/// ★ 세션 목록에서만 들어온다 = 수집이 정지된 상태다 (주행 판정 화면과 같은 진입 조건).
///   이 화면은 DB를 읽기만 한다.
///
/// ★ 고도 그래프·구간 자르기는 여기서 하지 않는다. 세션 목록의 GPX 내보내기를 쓴다.
class TrackMapScreen extends StatefulWidget {
  const TrackMapScreen({super.key, required this.session, this.tileProvider});

  final SessionSummary session;

  /// 테스트에서 네트워크 없이 타일을 채우려고만 쓴다. 앱에서는 넘기지 않는다.
  @visibleForTesting
  final TileProvider? tileProvider;

  @override
  State<TrackMapScreen> createState() => _TrackMapScreenState();
}

class _TrackMapScreenState extends State<TrackMapScreen> {
  final _map = MapController();

  /// TileLayer가 dispose 때 함께 닫는다. build마다 새로 만들면 매번 닫히고 새로 열린다.
  late final TileProvider _tiles = widget.tileProvider ??
      NetworkTileProvider(headers: {'User-Agent': K.osmTileUserAgent});

  bool _loading = true;
  TrackView? _view;
  int? _fetchedAt;

  String get _sid => widget.session.sessionId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final points = await AppDb.readTrackPoints(_sid);
    final snap = await AppDb.loadPredictions(_sid);
    final view = buildTrackView(
      points,
      labelsByTs:
          snap == null ? null : {for (final p in snap.points) p.ts: p.label},
    );
    if (!mounted) return;
    setState(() {
      _view = view;
      _fetchedAt = snap?.fetchedAt;
      _loading = false;
    });
  }

  static String _fmtDateTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// ★ 안드로이드 15부터 화면이 내비게이션 바 뒤까지 그려진다. 아래에 붙는 것은
  ///   전부 이만큼 올린다 - 안 올리면 OSM 저작권 표시가 바에 가려진다.
  double get _navInset => MediaQuery.paddingOf(context).bottom;

  CameraFit _fit(TrackView v) => CameraFit.coordinates(
        coordinates: v.bounds,
        padding: EdgeInsets.fromLTRB(40, 140, 40, 60 + _navInset),
        maxZoom: 17,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('주행 기록'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_fmtDateTime(widget.session.startedAt)} · ${_sid.substring(0, 8)}'
                '${widget.session.endedAt == null ? ' · 종료 기록 없음' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _body(_view!),
    );
  }

  Widget _body(TrackView v) {
    if (v.rawCount == 0) {
      return const Center(child: Text('이 세션에는 좌표가 없습니다.'));
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCameraFit: _fit(v),
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: K.osmTileUrl,
              tileProvider: _tiles,
              maxNativeZoom: 19,
            ),
            PolylineLayer(
              polylines: [
                for (final r in v.runs)
                  Polyline(
                    points: r.points,
                    strokeWidth: 5,
                    color: r.kind == null
                        ? Colors.deepPurple
                        : trackKindColor(r.kind!),
                    borderStrokeWidth: 1.5,
                    borderColor: Colors.white,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                // 도착을 먼저 넣어 출발이 위에 그려지게 한다 (원점 회귀 코스).
                if (v.end != null)
                  Marker(
                    point: v.end!,
                    width: 30,
                    height: 30,
                    child: const _Pin(icon: Icons.flag, color: Colors.red),
                  ),
                if (v.start != null)
                  Marker(
                    point: v.start!,
                    width: 30,
                    height: 30,
                    child: const _Pin(
                        icon: Icons.play_arrow, color: Colors.black87),
                  ),
              ],
            ),
          ],
        ),
        // ★ OSM 타일 정책상 저작권 표시는 필수다. 라이브러리 SimpleAttributionWidget은
        //   한 줄 고정이라 좁은 폰에서 넘친다. 같은 문구를 줄바꿈 가능하게 직접 둔다.
        Positioned(
          left: 0,
          right: 72,
          bottom: _navInset,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: ColoredBox(
              color: Colors.white.withValues(alpha: 0.8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text('© OpenStreetMap contributors',
                    style: TextStyle(fontSize: 11)),
              ),
            ),
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          top: 8,
          child: _infoCard(v),
        ),
        Positioned(
          right: 12,
          bottom: 44 + _navInset,
          child: FloatingActionButton.small(
            heroTag: null,
            tooltip: '궤적 전체 보기',
            onPressed: () => _map.fitCamera(_fit(v)),
            child: const Icon(Icons.center_focus_strong),
          ),
        ),
      ],
    );
  }

  Widget _infoCard(TrackView v) {
    final stats = v.stats;
    final small = TextStyle(fontSize: 11, color: Colors.grey.shade700);
    return Card(
      color: stats == null ? Colors.amber.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (stats == null)
              const Row(children: [
                Icon(Icons.info_outline, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '색 구분을 보려면 주행 판정 조회를 먼저 하세요',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ])
            else ...[
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final k in TrackKind.values)
                    if (stats.count(k) > 0) _legend(k, stats.count(k)),
                ],
              ),
              const SizedBox(height: 4),
              Text('판정 기준: 마지막 조회 ${_fmtDateTime(_fetchedAt!)}',
                  style: small),
              if (stats.notInPredictions > 0)
                Text(
                  '판정 없음 중 ${stats.notInPredictions}점은 판정 결과에 없는 좌표 '
                  '(서버 필터·미전송·조회 이후 전송)',
                  style: small,
                ),
            ],
            const SizedBox(height: 2),
            Wrap(
              spacing: 10,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const _Pin(
                      icon: Icons.play_arrow, color: Colors.black87, size: 14),
                  Text(' 출발', style: small),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const _Pin(icon: Icons.flag, color: Colors.red, size: 14),
                  Text(
                      ' 도착${widget.session.endedAt == null ? '(마지막 좌표)' : ''}',
                      style: small),
                ]),
                Text('표시 ${v.shownCount} / 원본 ${v.rawCount}점', style: small),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(TrackKind k, int count) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 5,
            decoration: BoxDecoration(
              color: trackKindColor(k),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          Text('${_kindKorean(k)} $count점', style: const TextStyle(fontSize: 12)),
        ],
      );

  static String _kindKorean(TrackKind k) => switch (k) {
        TrackKind.bike => '자전거',
        TrackKind.walk => '도보',
        TrackKind.others => '기타',
        TrackKind.unjudged => '판정 없음',
      };
}

class _Pin extends StatelessWidget {
  const _Pin({required this.icon, required this.color, this.size = 30});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: size / 15),
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.6),
    );
  }
}
