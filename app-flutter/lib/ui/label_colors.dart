import 'package:flutter/material.dart';

import '../data/track.dart';

/// 판정 색. 주행 판정 화면의 점과 주행 기록 지도의 선이 같은 색을 쓴다.
///
/// ★ 판정 없음은 회색이다. 지도에서는 흰 테두리를 둘러 도로 색과 구분한다.
Color trackKindColor(TrackKind kind) => switch (kind) {
      TrackKind.bike => Colors.green,
      TrackKind.walk => Colors.blue,
      TrackKind.others => Colors.deepOrange,
      TrackKind.unjudged => Colors.grey,
    };

Color predictionLabelColor(String? label) => trackKindColor(trackKindOf(label));
