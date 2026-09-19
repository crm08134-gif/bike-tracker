package io.github.crm08134.biketracker.ingest;

import java.util.UUID;

public record SessionRow(UUID sessionId, String deviceId, SessionState state, int nextSeq) {}
