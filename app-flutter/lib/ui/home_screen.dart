import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/app_db.dart';
import '../../data/permission_manager.dart';
import '../../state/tracking_controller.dart';
import 'prediction_screen.dart';
import 'server_settings_screen.dart';
import 'sessions_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  PermissionStatusReport? _perm;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    ref.read(trackingProvider.notifier).syncRunningState();
    // 전송 큐 상태. 서비스가 돌고 있으면 컨트롤러가 알아서 건너뛴다.
    ref.read(syncProvider.notifier).refreshCounts();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // 설정 앱에서 권한을 바꾸고 돌아온 경우 반영
    if (s == AppLifecycleState.resumed) {
      _refresh();
      // 백그라운드에 있던 사이 서비스가 내려갔거나 종료 처리가 끝났을 수 있다.
      ref.read(trackingProvider.notifier).syncRunningState();
      ref.read(syncProvider.notifier).refreshCounts();
    }
  }

  Future<void> _refresh() async {
    final r = await PermissionManager.check();
    if (mounted) setState(() => _perm = r);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 권한 요청 순서 (반드시 이 순서) ──
  Future<void> _runPermissionFlow() async {
    if (!await PermissionManager.ensureLocationService()) {
      _toast('기기 위치(GPS)를 켜주세요.');
      return _refresh();
    }
    if (!await PermissionManager.requestFineLocation()) {
      _toast('정밀 위치 권한이 필요합니다.');
      return _refresh();
    }
    if (!await PermissionManager.requestNotification()) {
      _toast('알림 권한이 없으면 포그라운드 서비스가 표시되지 않습니다.');
    }

    // 백그라운드 위치는 사전 안내 후 요청
    if (!await PermissionManager.requestBackgroundLocation()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('위치 "항상 허용"이 필요합니다'),
          content: const Text(
            '화면을 끈 상태에서도 GPS를 수집하려면 위치 권한을 "항상 허용"으로 '
            '설정해야 합니다.\n\n'
            'Android 11부터는 팝업으로 즉시 승인할 수 없고, 설정 앱에서 직접 '
            '선택해야 합니다.\n\n'
            '설정 → 권한 → 위치 → "항상 허용"을 선택해 주세요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('나중에'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('설정 열기'),
            ),
          ],
        ),
      );
      if (go == true) await PermissionManager.openSettings();
      return _refresh();
    }

    if (!await PermissionManager.requestIgnoreBatteryOptimizations()) {
      _toast('배터리 최적화 예외를 허용하면 장시간 수집이 안정적입니다.');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(trackingProvider);
    final ctl = ref.read(trackingProvider.notifier);
    final sync = ref.watch(syncProvider);
    final perm = _perm;
    final canStart = perm?.canStart ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('궤적 로거 (2단계)'),
        actions: [
          // 수집 중에도 연다. DB를 건드리지 않는다 (server_settings_screen.dart).
          IconButton(
            icon: const Icon(Icons.dns_outlined),
            tooltip: '서버 설정',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ServerSettingsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: '세션 목록',
            onPressed: st.running || st.stopping
                ? null // 수집 중에는 UI가 DB를 열지 않는다 (isolate 충돌 방지)
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SessionsScreen(),
                      ),
                    ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (perm != null && !canStart) _permissionCard(perm),
            _labelSelector(st, ctl),
            const SizedBox(height: 16),
            _statsCard(st),
            const SizedBox(height: 16),
            _lastFixCard(st),
            const SizedBox(height: 16),
            _syncCard(st, sync),
            const SizedBox(height: 24),
            SizedBox(
              height: 64,
              child: st.stopping
                  ? FilledButton.icon(
                      icon: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      label: const Text('종료 처리 중...',
                          style: TextStyle(fontSize: 18)),
                      onPressed: null,
                    )
                  : st.running
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                          ),
                          icon: const Icon(Icons.stop),
                          label: const Text('추적 종료',
                              style: TextStyle(fontSize: 18)),
                          onPressed: () async {
                            await ctl.stop();
                            // 추적 중 전송을 하지 않으므로 방금 만든 배치가
                            // 전부 큐에 남아 있다. 바로 세어서 보여준다.
                            await ref.read(syncProvider.notifier).refreshCounts();
                            _toast('세션이 저장되었습니다. 서버로 보내려면 [서버로 보내기]를 누르세요.');
                          },
                        )
                      : FilledButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('추적 시작',
                              style: TextStyle(fontSize: 18)),
                          onPressed: !canStart
                              ? null
                              : () async {
                                  final err = await ctl.start();
                                  if (err != null) _toast(err);
                                },
                        ),
            ),
            const SizedBox(height: 12),
            Text(
              st.sessionId == null
                  ? '세션 없음'
                  : 'session ${st.sessionId!.substring(0, 8)}',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionCard(PermissionStatusReport perm) {
    return Card(
      color: Colors.amber.shade50,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('시작하려면 아래 항목이 필요합니다',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...perm.missing.map((m) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    const Icon(Icons.remove_circle_outline,
                        size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(child: Text(m)),
                  ]),
                )),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton(
                onPressed: _runPermissionFlow,
                child: const Text('권한 설정하기'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: _refresh, child: const Text('다시 확인')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _labelSelector(TrackingState st, TrackingController ctl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('현재 이동수단 라벨',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
        const SizedBox(height: 8),
        Row(
          children: TripLabel.all.map((l) {
            final selected = st.label == l;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: GestureDetector(
                  onTap: st.running ? () => ctl.setLabel(l) : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 84,
                    decoration: BoxDecoration(
                      color: selected
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade300,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (l == TripLabel.other)
                          _otherModesGrid()
                        else
                          Text(TripLabel.emoji(l),
                              style: const TextStyle(fontSize: 30)),
                        const SizedBox(height: 4),
                        Text(TripLabel.korean(l),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            )),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        if (!st.running)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('추적을 시작하면 라벨을 변경할 수 있습니다.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ),
      ],
    );
  }

  /// '기타' 칸의 그림: 비행기·배·기차·버스를 2×2로 나눠 보여준다.
  /// 다른 칸의 이모지(30pt 한 줄)와 높이를 비슷하게 맞췄다.
  Widget _otherModesGrid() {
    const style = TextStyle(fontSize: 15, height: 1.15);
    Widget row(String a, String b) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(a, style: style),
            const SizedBox(width: 4),
            Text(b, style: style),
          ],
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row('✈️', '🚢'),
        row('🚆', '🚌'),
      ],
    );
  }

  Widget _statsCard(TrackingState st) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          children: [
            Text(st.elapsedText,
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                )),
            const SizedBox(height: 4),
            Text('경과 시간',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const Divider(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _metric('${st.count}', '수집 포인트'),
                _metric('${st.buffered}', '버퍼 대기'),
                _metric(
                  st.elapsedMs > 0
                      ? (st.count / (st.elapsedMs / 1000)).toStringAsFixed(2)
                      : '-',
                  '평균 Hz',
                ),
              ],
            ),
            const Divider(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _metric('${st.queued}', '전송 대기'),
                // ★ 이 숫자가 계속 오르면 GNSS 시각이 역행하고 있다는 뜻이다.
                //   덤프 CSV를 다시 분석하지 않아도 여기서 바로 보인다 (§9-4).
                _metric('${st.droppedTs}', '버린 ts'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 미전송 배치를 서버로 보내는 카드.
  ///
  /// ★ 추적 중에는 버튼을 막는다. 이유는 "어차피 전송이 돌고 있어서"가 아니라
  ///   (지금은 돌지 않는다) 전송 전용 서비스와 수집 서비스가 같은 `batches`를
  ///   쓰기 때문이다.
  Widget _syncCard(TrackingState st, SyncState sync) {
    final ctl = ref.read(syncProvider.notifier);
    final tracking = st.running || st.stopping;
    final result = sync.result;

    // 수집 중에는 DB를 읽지 않으므로 서비스가 보내주는 큐 길이를 쓴다.
    final unsent = tracking ? st.queued : sync.unsent;

    if (!tracking && !sync.running && unsent == 0 && result == null) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.cloud_upload_outlined,
                  size: 18, color: Colors.grey.shade700),
              const SizedBox(width: 8),
              Text(
                sync.running ? '서버로 전송 중' : '서버 전송',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (sync.dead > 0 && !sync.running)
                Text('DEAD ${sync.dead}건',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
            ]),
            const SizedBox(height: 10),
            if (sync.running) ...[
              LinearProgressIndicator(
                value: (sync.sent + sync.remaining) == 0
                    ? null
                    : sync.sent / (sync.sent + sync.remaining),
              ),
              const SizedBox(height: 8),
              Text('남은 ${sync.remaining}건 · 전송 ${sync.sent}건'
                  '${sync.failed > 0 ? ' · 실패 ${sync.failed}회' : ''}'),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: ctl.cancel, child: const Text('취소')),
              ),
            ] else ...[
              if (unsent > 0)
                Text('서버로 보내지 않은 배치 $unsent건이 폰에 있습니다.',
                    style: const TextStyle(fontSize: 13)),
              if (unsent > 0) const SizedBox(height: 10),
              if (unsent > 0)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.upload),
                    label: Text('미전송 $unsent건 서버로 보내기'),
                    onPressed: tracking
                        ? null
                        : () async {
                            final err = await ctl.sync();
                            if (err != null) _toast(err);
                          },
                  ),
                ),
              if (tracking)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('추적 종료 후 전송할 수 있습니다.',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ),
              if (result != null) _syncResult(result),
            ],
          ],
        ),
      ),
    );
  }

  /// 완료 표시. 성공 건수만 보여주면 seq 갭으로 서버에 아무것도 안 붙었는데도
  /// 정상으로 믿게 된다. 남은 건수와 DEAD를 항상 같이 보여준다.
  Widget _syncResult(SyncResult r) {
    final bad = !r.ok || r.remaining > 0 || r.deadTotal > 0;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bad ? Colors.amber.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${r.reasonText} · ${r.summary}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (r.deadTotal > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'DEAD 배치는 다시 보내지 않습니다. 그 세션은 DEAD 번호 뒤의 배치가 '
                '서버에 이어 붙지 않습니다.',
                style: TextStyle(fontSize: 11, color: Colors.red.shade700),
              ),
            ),
          if (!r.ok) ...[
            const SizedBox(height: 6),
            Text('보낸 주소 ${r.url}${r.usingDefaultUrl ? ' (저장된 주소 없음 - 기본값)' : ''}',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade700,
                    fontFamily: 'monospace')),
            if (r.error != null)
              Text(r.error!,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
          const SizedBox(height: 4),
          Row(children: [
            if (r.sent > 0)
              TextButton(
                onPressed: () => _openPredictions(r),
                child: const Text('판정 새로고침하러 가기'),
              ),
            const Spacer(),
            TextButton(
              onPressed: ref.read(syncProvider.notifier).clearResult,
              child: const Text('닫기'),
            ),
          ]),
        ],
      ),
    );
  }

  /// 방금 보낸 세션이 하나면 그 판정 화면으로, 여럿이면 세션 목록으로.
  /// 판정 캐시는 자동으로 갱신되지 않으므로 그 화면에서 새로고침을 눌러야 한다.
  Future<void> _openPredictions(SyncResult r) async {
    Widget target = const SessionsScreen();
    if (r.sessions.length == 1) {
      final list = await AppDb.listSessions();
      await AppDb.close();
      for (final s in list) {
        if (s.sessionId == r.sessions.first) {
          target = PredictionScreen(session: s);
          break;
        }
      }
    }
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => target));
    if (mounted) await ref.read(syncProvider.notifier).refreshCounts();
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

  Widget _lastFixCard(TrackingState st) {
    final stale = st.staleMs;
    Color color = Colors.green;
    String text = 'GPS 정상';
    if (stale < 0) {
      color = Colors.grey;
      text = '첫 수신 대기 중';
    } else if (stale >= K.staleAlertMs) {
      color = Colors.red;
      text = '${(stale / 1000).toStringAsFixed(0)}초째 수신 없음';
    } else if (stale >= K.staleWarnMs) {
      color = Colors.orange;
      text = '${(stale / 1000).toStringAsFixed(0)}초째 수신 없음';
    } else {
      text = '${(stale / 1000).toStringAsFixed(1)}초 전 수신';
    }

    final kmh = st.spd == null ? null : (st.spd! * 3.6);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(text,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _kv('정확도',
                    st.acc == null ? '-' : '${st.acc!.toStringAsFixed(1)} m'),
                _kv('속도', kmh == null ? '-' : '${kmh.toStringAsFixed(1)} km/h'),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              st.lat == null
                  ? '좌표 없음'
                  : '${st.lat!.toStringAsFixed(6)}, ${st.lng!.toStringAsFixed(6)}',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Row(children: [
        Text('$k ',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        Text(v,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ]);
}
