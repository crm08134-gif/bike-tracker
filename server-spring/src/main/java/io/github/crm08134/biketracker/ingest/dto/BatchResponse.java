package io.github.crm08134.biketracker.ingest.dto;

import io.github.crm08134.biketracker.ingest.SessionState;

/**
 * 앱은 이 응답만 받습니다. 판별 결과는 돌아가지 않습니다 (계획서 3절).
 *
 * @param nextSeq 서버가 다음에 기다리는 배치 번호. 앱이 재전송 지점을 잡는 데 씁니다.
 */
public record BatchResponse(SessionState sessionState, int nextSeq) {}
