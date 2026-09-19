import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:my_gps_tracker/data/app_db.dart';

/// AppDb가 실제로 여는 파일 경로. 테스트마다 지우고 시작한다.
late String dbPath;

/// setUpAll에서 부른다.
///
/// ★ [tag]로 테스트 파일마다 DB 디렉터리를 갈라 놓는다. `flutter test`는
///   파일들을 **동시에** 돌리는데, 전부 같은 경로의 bike_tracker.db를 열면
///   한 파일의 setUp이 다른 파일이 쓰고 있는 파일을 지운다.
void initTestDb(String tag) {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _tag = tag;
}

String _tag = 'default';

/// ★ 한 번만 읽는다. setDatabasesPath로 바꾼 뒤 다시 getDatabasesPath를
///   부르면 방금 설정한 경로가 나와서, setUp마다 디렉터리가 한 겹씩
///   깊어지다 경로 길이 한계에서 "unable to open database file"이 난다.
String? _root;

Future<void> resetDb() async {
  await AppDb.close();
  final root = _root ??= await databaseFactory.getDatabasesPath();
  final dir = p.join(root, 'test_$_tag');
  await Directory(dir).create(recursive: true);
  await databaseFactory.setDatabasesPath(dir);
  // AppDb가 쓰는 파일 이름과 같아야 한다. 이 이름은 1단계 데이터가 걸려 있어
  // 바꾸지 않기로 했으므로 여기 하드코딩해도 안전하다.
  dbPath = p.join(dir, 'bike_tracker.db');
  final f = File(dbPath);
  if (f.existsSync()) await f.delete();
}

Future<void> closeDb() => AppDb.close();

Future<bool> tableExists(DatabaseExecutor db, String name) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [name],
  );
  return rows.isNotEmpty;
}
