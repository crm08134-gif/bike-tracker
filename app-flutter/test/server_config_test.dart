import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_gps_tracker/core/constants.dart';
import 'package:my_gps_tracker/data/api_client.dart';
import 'package:my_gps_tracker/data/server_config.dart';

/// 받은 요청의 전체 URL을 남기고, 정해 준 응답(또는 전송 실패)을 돌려준다.
class _ProbeGateway implements HttpClientAdapter {
  _ProbeGateway({this.status = 404, this.body, this.transportError});

  final int status;
  final Map<String, Object?>? body;
  final DioExceptionType? transportError;
  final List<String> urls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    urls.add('${options.method} ${options.uri}');
    if (transportError != null) {
      throw DioException(requestOptions: options, type: transportError!, message: 'fake');
    }
    return ResponseBody.fromString(jsonEncode(body ?? const {}), status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('ServerConfig.normalize', () {
    test('http://host:port 를 받고 끝의 / 와 공백을 뗀다', () {
      expect(ServerConfig.normalize('http://192.168.0.10:8080'), 'http://192.168.0.10:8080');
      expect(ServerConfig.normalize('  http://127.0.0.1:8080/  '), 'http://127.0.0.1:8080');
      expect(ServerConfig.normalize('HTTP://MyPC.local:8080'), 'http://mypc.local:8080');
      expect(ServerConfig.normalize('http://[::1]:8080'), 'http://[::1]:8080');
      // 기본 포트도 적은 그대로 남긴다 (다시 검증해도 통과해야 한다).
      expect(ServerConfig.normalize('http://10.0.0.1:80'), 'http://10.0.0.1:80');
      expect(ServerConfig.normalize(ServerConfig.normalize('http://10.0.0.1:80')),
          'http://10.0.0.1:80');
    });

    test('https는 포트를 생략할 수 있다', () {
      expect(ServerConfig.normalize('https://tracker.example.com'), 'https://tracker.example.com');
      expect(ServerConfig.normalize('https://tracker.example.com:8443'),
          'https://tracker.example.com:8443');
    });

    test('형식이 틀리면 메시지를 준다', () {
      for (final bad in [
        '',
        '   ',
        '192.168.0.10:8080', // 스킴 없음
        'localhost:8080',
        'ftp://host:21',
        'http://192.168.0.10', // http인데 포트 없음
        'http://host:8080/api/v1', // 경로
        'http://host:8080?x=1',
        'http://user:pw@host:8080',
        'http://host:0',
        'http://host:70000',
        'http://:8080',
      ]) {
        expect(ServerConfig.validate(bad), isNotNull, reason: bad);
      }
      expect(ServerConfig.validate('http://host:8080'), isNull);
    });

    test('기본값 자체도 검증을 통과한다', () {
      expect(ServerConfig.validate(K.defaultApiBaseUrl), isNull);
    });
  });

  group('ServerConfig 저장', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('저장값이 없으면 기본값이다', () async {
      expect(await ServerConfig.loadSaved(), isNull);
      expect(await ServerConfig.load(), K.defaultApiBaseUrl);
    });

    test('저장하면 정규화된 값이 적용되고, 지우면 기본값으로 돌아간다', () async {
      expect(await ServerConfig.save('http://100.64.0.2:8080/'), 'http://100.64.0.2:8080');
      expect(await ServerConfig.load(), 'http://100.64.0.2:8080');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(K.prefsServerBaseUrl), 'http://100.64.0.2:8080');

      await ServerConfig.clear();
      expect(await ServerConfig.load(), K.defaultApiBaseUrl);
    });

    test('형식이 틀리면 저장하지 않는다', () async {
      await ServerConfig.save('http://100.64.0.2:8080');
      await expectLater(ServerConfig.save('http://oops'), throwsFormatException);
      expect(await ServerConfig.load(), 'http://100.64.0.2:8080');
    });
  });

  group('ApiClient 주소', () {
    test('baseUrl을 바꾸면 다음 요청부터 새 주소로 간다', () async {
      final gw = _ProbeGateway(body: {'error': 'SESSION_NOT_FOUND', 'retryable': false});
      final api = ApiClient(baseUrl: 'http://old.local:8080', adapter: gw);

      await api.checkServer();
      api.baseUrl = 'http://new.local:9090';
      await api.checkServer();

      expect(gw.urls, [
        'GET http://old.local:8080/api/v1/sessions/${ApiClient.probeSessionId}/predictions',
        'GET http://new.local:9090/api/v1/sessions/${ApiClient.probeSessionId}/predictions',
      ]);
    });
  });

  group('ApiClient.checkServer', () {
    test('404 SESSION_NOT_FOUND 는 연결 성공이다', () async {
      final api = ApiClient(
          baseUrl: 'http://fake:8080',
          adapter: _ProbeGateway(
              body: {'error': 'SESSION_NOT_FOUND', 'detail': '없는 세션입니다', 'retryable': false}));
      final r = await api.checkServer();
      expect(r.ok, isTrue);
      expect(r.detail, isNull);
    });

    test('오류 형식이 다른 404 는 다른 서버로 본다', () async {
      final api = ApiClient(
          baseUrl: 'http://fake:8080', adapter: _ProbeGateway(body: {'message': 'Not Found'}));
      final r = await api.checkServer();
      expect(r.ok, isFalse);
      expect(r.detail, contains('404'));
    });

    test('5xx 는 서버 오류로 알린다', () async {
      final api = ApiClient(
          baseUrl: 'http://fake:8080',
          adapter: _ProbeGateway(
              status: 500, body: {'error': 'INTERNAL_ERROR', 'retryable': true}));
      final r = await api.checkServer();
      expect(r.ok, isFalse);
      expect(r.detail, contains('500'));
    });

    test('연결 실패는 실패로 알린다', () async {
      for (final t in [DioExceptionType.connectionError, DioExceptionType.connectionTimeout]) {
        final api =
            ApiClient(baseUrl: 'http://fake:8080', adapter: _ProbeGateway(transportError: t));
        final r = await api.checkServer();
        expect(r.ok, isFalse, reason: t.name);
        expect(r.detail, contains(t.name));
      }
    });
  });
}
