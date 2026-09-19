package io.github.crm08134.biketracker.segment;

/**
 * 한 좌표가 두 묶음에 겹쳐 들어갈 때 어느 판정을 쓸지. 계획서 7절의 미결 사항입니다.
 */
public enum OverlapStrategy {

    /** 두 묶음의 확률을 평균한 뒤 가장 높은 라벨. 계획서의 제안입니다. */
    AVERAGE_PROBS,

    /** 덮는 묶음이 전부 bike 일 때만 bike. DB 오염은 적지만 궤적이 자주 끊깁니다. */
    STRICT_BIKE,

    /** 나중 묶음의 판정을 그대로. 가장 단순합니다. */
    LATEST_WINDOW
}
