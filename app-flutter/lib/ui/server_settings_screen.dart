import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../../core/constants.dart';
import '../../data/api_client.dart';
import '../../data/server_config.dart';

/// 서버 주소 설정. 홈 화면 AppBar에서 들어온다.
///
/// ★ 수집 중에도 연다. DB를 건드리지 않고, USB를 뽑고 다른 경로로 바꿔야 하는
///   때가 바로 수집 중이다. 저장하면 떠 있는 서비스에도 이벤트로 알려
///   재시작 없이 다음 전송부터 새 주소로 간다.
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  final _controller = TextEditingController();

  bool _loading = true;

  /// 저장된 값. null이면 기본값을 쓰는 중이다.
  String? _saved;
  String? _inputError;

  bool _testing = false;
  bool _saving = false;
  ServerCheck? _check;

  /// [_check]를 받은 주소. 입력을 고치면 결과가 어느 주소 것인지 헷갈리지 않게 같이 보여준다.
  String? _checkedUrl;

  String get _applied => _saved ?? K.defaultApiBaseUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await ServerConfig.loadSaved();
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _controller.text = saved ?? K.defaultApiBaseUrl;
      _loading = false;
    });
  }

  void _onChanged(String v) {
    setState(() => _inputError = ServerConfig.validate(v));
  }

  Future<void> _test() async {
    final err = ServerConfig.validate(_controller.text);
    if (err != null) {
      setState(() => _inputError = err);
      return;
    }
    final url = ServerConfig.normalize(_controller.text);
    setState(() {
      _testing = true;
      _check = null;
    });
    final api = ApiClient(baseUrl: url);
    try {
      final r = await api.checkServer();
      if (!mounted) return;
      setState(() {
        _check = r;
        _checkedUrl = url;
      });
    } finally {
      api.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final err = ServerConfig.validate(_controller.text);
    if (err != null) {
      setState(() => _inputError = err);
      return;
    }
    setState(() => _saving = true);
    try {
      final url = await ServerConfig.save(_controller.text);
      final pushed = await _pushToService(url);
      if (!mounted) return;
      setState(() {
        _saved = url;
        _controller.text = url;
      });
      _toast(pushed ? '저장했습니다. 수집 중인 전송에도 바로 적용됩니다.' : '저장했습니다.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetToDefault() async {
    setState(() => _saving = true);
    try {
      await ServerConfig.clear();
      final pushed = await _pushToService(K.defaultApiBaseUrl);
      if (!mounted) return;
      setState(() {
        _saved = null;
        _controller.text = K.defaultApiBaseUrl;
        _inputError = null;
      });
      _toast(pushed ? '기본값으로 되돌렸습니다. 수집 중인 전송에도 적용됩니다.' : '기본값으로 되돌렸습니다.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 서비스가 떠 있으면 새 주소를 알린다. 떠 있지 않으면 다음 시작 때 prefs에서 읽는다.
  Future<bool> _pushToService(String url) async {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) return false;
    service.invoke(K.evtSetServerUrl, {'url': url});
    return true;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('서버 설정')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _appliedCard(context),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '서버 주소',
                    hintText: 'http://192.168.0.10:8080',
                    helperText: 'http://host:port 형식. 경로(/api/...)는 적지 않습니다.',
                    errorText: _inputError,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: _onChanged,
                  onSubmitted: (_) => _test(),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testing || _saving ? null : _test,
                        icon: _testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('연결 테스트'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _testing || _saving ? null : _save,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('저장'),
                      ),
                    ),
                  ],
                ),
                if (_check != null) ...[
                  const SizedBox(height: 16),
                  _checkCard(context, _check!),
                ],
                const SizedBox(height: 24),
                TextButton(
                  onPressed: _saved == null || _testing || _saving ? null : _resetToDefault,
                  child: const Text('기본값으로 되돌리기 (${K.defaultApiBaseUrl})'),
                ),
              ],
            ),
    );
  }

  Widget _appliedCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('현재 적용 중인 주소', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(_applied, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _saved == null ? '기본값 (빌드 때 정한 주소)' : '앱에서 저장한 주소',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              '주행 데이터 전송과 판정 조회에 모두 이 주소를 씁니다.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkCard(BuildContext context, ServerCheck r) {
    final theme = Theme.of(context);
    final color = r.ok ? Colors.green.shade700 : theme.colorScheme.error;
    return Card(
      child: ListTile(
        leading: Icon(r.ok ? Icons.check_circle : Icons.error_outline, color: color),
        title: Text(r.message, style: TextStyle(color: color)),
        subtitle: Text(
          [
            '$_checkedUrl · ${r.elapsedMs}ms',
            if (r.detail != null) r.detail!,
          ].join('\n'),
          style: const TextStyle(fontSize: 12),
        ),
        isThreeLine: r.detail != null,
      ),
    );
  }
}
