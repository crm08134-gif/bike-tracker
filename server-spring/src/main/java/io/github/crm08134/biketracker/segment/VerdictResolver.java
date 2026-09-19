package io.github.crm08134.biketracker.segment;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.springframework.stereotype.Component;

import io.github.crm08134.biketracker.config.TrackerProperties;

/**
 * 좌표 하나를 덮는 묶음들의 결과를 하나의 판정으로 합칩니다. 계획서 7절.
 *
 * <p>덮는 묶음이 없는 좌표(마지막 묶음 뒤에 남은 1~99점)는 마지막 묶음의 판정을 그대로 받습니다.
 */
@Component
public class VerdictResolver {

    private final WindowSpec spec;
    private final OverlapStrategy strategy;
    private final String bikeLabel;

    public VerdictResolver(TrackerProperties props) {
        this.spec = props.windowSpec();
        this.strategy = props.getOverlapStrategy();
        this.bikeLabel = props.getBikeLabel();
    }

    /**
     * @param idx         구간 안에서의 좌표 순번
     * @param windows     이 구간에서 계산이 끝난 묶음들. 번호 순으로 정렬돼 있어야 합니다.
     * @return 판정. 묶음이 하나도 없으면 null (200점 미만이라 버릴 구간)
     */
    public Verdict resolve(int idx, List<WindowResult> windows) {
        if (windows.isEmpty()) {
            return null;
        }
        List<WindowResult> covering = covering(idx, windows);
        if (covering.isEmpty()) {
            // 끝부분: 마지막 묶음의 판정을 그대로 붙입니다.
            covering = List.of(windows.get(windows.size() - 1));
        }
        return switch (strategy) {
            case AVERAGE_PROBS -> averaged(covering);
            case STRICT_BIKE -> strictBike(covering);
            case LATEST_WINDOW -> single(covering.get(covering.size() - 1));
        };
    }

    private List<WindowResult> covering(int idx, List<WindowResult> windows) {
        int first = spec.firstCoveringWindow(idx);
        int last = spec.lastCoveringWindow(idx, windows.size());
        List<WindowResult> out = new ArrayList<>(2);
        for (int w = first; w <= last; w++) {
            out.add(windows.get(w));
        }
        return out;
    }

    private Verdict averaged(List<WindowResult> covering) {
        Map<String, Double> sum = new HashMap<>();
        for (WindowResult w : covering) {
            w.probs().forEach((k, v) -> sum.merge(k, v, Double::sum));
        }
        int n = covering.size();
        Map<String, Double> mean = new HashMap<>(sum.size());
        sum.forEach((k, v) -> mean.put(k, v / n));
        return new Verdict(argmax(mean), mean, covering.get(0).modelVersion());
    }

    private Verdict strictBike(List<WindowResult> covering) {
        boolean allBike = covering.stream().allMatch(w -> bikeLabel.equals(w.label()));
        Verdict base = averaged(covering);
        if (allBike) {
            return base;
        }
        // bike 가 아닌 묶음이 하나라도 있으면 bike 를 뺀 나머지 중 최고를 고릅니다.
        Map<String, Double> withoutBike = new HashMap<>(base.probs());
        withoutBike.remove(bikeLabel);
        String label = withoutBike.isEmpty() ? base.label() : argmax(withoutBike);
        return new Verdict(label, base.probs(), base.modelVersion());
    }

    private Verdict single(WindowResult w) {
        return new Verdict(w.label(), w.probs(), w.modelVersion());
    }

    private static String argmax(Map<String, Double> probs) {
        String best = null;
        double bestValue = Double.NEGATIVE_INFINITY;
        for (Map.Entry<String, Double> e : probs.entrySet()) {
            // 동점이면 라벨 알파벳 순으로 고정합니다. 같은 입력이면 항상 같은 결과가 나와야 합니다.
            if (e.getValue() > bestValue
                    || (e.getValue() == bestValue && best != null && e.getKey().compareTo(best) < 0)) {
                bestValue = e.getValue();
                best = e.getKey();
            }
        }
        return best;
    }
}
