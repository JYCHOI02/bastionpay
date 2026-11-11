package com.san.bastionpay.admin;

import com.san.bastionpay.audit.Actor;
import com.san.bastionpay.audit.AuditLog;
import com.san.bastionpay.audit.AuditLogRepository;
import com.san.bastionpay.audit.EventOutcome;
import com.san.bastionpay.audit.SecurityEvent;
import com.san.bastionpay.audit.SecurityEventEntity;
import com.san.bastionpay.audit.SecurityEventRecorder;
import com.san.bastionpay.audit.SecurityEventRepository;
import com.san.bastionpay.audit.SecurityEventType;
import com.san.bastionpay.audit.Severity;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;

/**
 * 인시던트 티켓. 출발지 IP 의 보안 이벤트를 모아 사람이 읽는 요약(타임라인·집계·조치)을 만든다.
 * 같은 IP 의 열린 티켓이 있으면 새로 만들지 않고 갱신하며(중복 방지), 이미 종료한 티켓의 사건은 다시 모으지 않는다.
 * n8n 같은 자동화는 이 서비스(API)로 티켓을 만들고, 관리자는 대시보드에서 같은 기능을 쓴다.
 */
@Service
public class IncidentService {

    public static final int DEFAULT_HOURS = 24;
    public static final int MAX_HOURS = 24 * 30;
    private static final int TIMELINE_LINES = 20;
    private static final int MAX_EVENTS = 500;
    private static final int BULK_MAX = 500;
    private static final ZoneId KST = ZoneId.of("Asia/Seoul");
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    /** "이미 취해진 조치"로 요약에 적는 이벤트 종류. */
    private static final Set<SecurityEventType> RESPONSE_TYPES = EnumSet.of(SecurityEventType.IP_BLOCKED, SecurityEventType.IP_UNBLOCKED,
            SecurityEventType.ACCOUNT_LOCKED, SecurityEventType.ACCOUNT_UNLOCKED, SecurityEventType.ROLE_REVOKED);

    public record CreateResult(Incident incident, boolean created) {}

    public record Counts(Map<String, Long> byStatus, Map<String, Long> openBySeverity) {}

    private final IncidentRepository incidents;
    private final SecurityEventRepository events;
    private final SecurityEventRecorder recorder;
    private final AuditLogRepository audits;

    public IncidentService(IncidentRepository incidents, SecurityEventRepository events, SecurityEventRecorder recorder,
                           AuditLogRepository audits) {
        this.incidents = incidents;
        this.events = events;
        this.recorder = recorder;
        this.audits = audits;
    }

    /**
     * 티켓을 만들거나(열린 티켓이 없을 때) 갱신한다.
     *
     * @param title    비우면 "보안 인시던트: IP (n건)" 으로 자동 생성
     * @param severity 비우면 모은 이벤트 중 가장 높은 심각도(LOW 이상)
     * @param hours    최근 몇 시간의 이벤트를 모을지(기본 24, 최대 720)
     */
    @Transactional
    public CreateResult create(String srcIp, String title, Severity severity, Integer hours, Actor actor) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        int window = hours == null || hours < 1 ? DEFAULT_HOURS : Math.min(hours, MAX_HOURS);
        LocalDateTime since = now.minus(Duration.ofHours(window));
        // 같은 IP 의 마지막 종료 티켓 이후 사건만 모은다. 같은 시각은 포함해서(새 증거를 놓치는 것보다 한 건 겹치는 편이 안전하다)
        var lastClosed = incidents.findFirstBySrcIpAndStatusAndClosedAtIsNotNullOrderByClosedAtDesc(srcIp, Incident.Status.CLOSED);
        if (lastClosed.isPresent() && lastClosed.get().getClosedAt().isAfter(since)) since = lastClosed.get().getClosedAt();

        List<SecurityEventEntity> collected = events.findBySourceIpAndOccurredAtGreaterThanEqualOrderByIdDesc(srcIp, since, PageRequest.of(0, MAX_EVENTS));
        Severity worst = worstOf(collected);
        Summary summary = summarize(srcIp, collected, worst);
        // 티켓 등급은 Graylog/n8n 이 보낸 severity 를 따른다. 넘어온 값이 없을 때만 수집한 이벤트 중 가장 높은 등급(worst)으로 떨어진다.
        Severity wanted = severity != null && severity.compareTo(Severity.LOW) >= 0 ? severity : worst;
        String ticketTitle = title == null || title.isBlank() ? "보안 인시던트: " + srcIp + " (" + collected.size() + "건)" : title.strip();
        if (ticketTitle.length() > 200) ticketTitle = ticketTitle.substring(0, 200);

        Incident incident = incidents.findBySrcIpAndStatus(srcIp, Incident.Status.OPEN).orElse(null);
        boolean created = incident == null;
        if (created) incident = new Incident(srcIp, actor.label(), now);
        incident.refresh(ticketTitle, wanted, summary.text(), collected.size(), summary.actions(), now);
        try {
            incident = incidents.saveAndFlush(incident);
        } catch (DataIntegrityViolationException e) {
            // 같은 IP 의 티켓이 동시에 만들어졌다: 먼저 만들어진 열린 티켓을 갱신한다
            incident = incidents.findBySrcIpAndStatus(srcIp, Incident.Status.OPEN).orElseThrow(() -> e);
            incident.refresh(ticketTitle, wanted, summary.text(), collected.size(), summary.actions(), now);
            incident = incidents.saveAndFlush(incident);
            created = false;
        }
        SecurityEvent event = recorder.record(SecurityEvent.of(SecurityEventType.INCIDENT_CREATED, EventOutcome.SUCCESS)
                .sourceIp(srcIp).reasonCode(created ? "TICKET_CREATED" : "TICKET_UPDATED"));
        audits.save(new AuditLog(event, actor.type(), actor.memberId(), null));
        return new CreateResult(incident, created);
    }

    /** 티켓 하나를 종료한다. 없거나 이미 종료됐으면 false(종료 시각을 덮어쓰지 않는다). */
    @Transactional
    public boolean close(long id, Actor actor) {
        Incident incident = incidents.findById(id).orElse(null);
        if (incident == null || !incident.isOpen()) return false;
        incident.close(actor.label(), LocalDateTime.now(ZoneOffset.UTC));
        incidents.save(incident);
        record(incident, actor);
        return true;
    }

    /** 고른 티켓들을 종료한다. 종료한 개수를 돌려준다(이미 종료됐거나 없는 것은 건너뛴다). */
    @Transactional
    public int closeMany(List<Long> ids, Actor actor) {
        int closed = 0;
        for (Long id : ids.stream().distinct().limit(BULK_MAX).toList()) if (close(id, actor)) closed++;
        return closed;
    }

    /** 조건에 맞는 열린 티켓 전부를 종료한다(심각도를 주면 그 심각도만). */
    @Transactional
    public int closeAllOpen(Severity severity, Actor actor) {
        int closed = 0;
        for (Incident i : incidents.search(Incident.Status.OPEN, severity, null, PageRequest.of(0, BULK_MAX)).getContent()) {
            if (close(i.getId(), actor)) closed++;
        }
        return closed;
    }

    @Transactional(readOnly = true)
    public Page<Incident> list(Incident.Status status, Severity severity, int page, int size) {
        return list(status, severity, null, page, size);
    }

    /** ip 는 출발지 IP 의 일부(비우면 전체). */
    @Transactional(readOnly = true)
    public Page<Incident> list(Incident.Status status, Severity severity, String ip, int page, int size) {
        String like = ip == null || ip.isBlank() ? null : com.san.bastionpay.member.MemberAdminQuery.escapeLike(ip.strip());
        return incidents.search(status, severity, like, PageRequest.of(Math.max(page, 1) - 1, size));
    }

    @Transactional(readOnly = true)
    public Counts counts() {
        Map<String, Long> byStatus = new LinkedHashMap<>();
        incidents.countByStatus().forEach(c -> byStatus.put(String.valueOf(c.getKey()), c.getCnt()));
        Map<String, Long> open = new LinkedHashMap<>();
        incidents.openBySeverity().forEach(c -> open.put(String.valueOf(c.getKey()), c.getCnt()));
        return new Counts(byStatus, open);
    }

    private void record(Incident incident, Actor actor) {
        SecurityEvent event = recorder.record(SecurityEvent.of(SecurityEventType.INCIDENT_CLOSED, EventOutcome.SUCCESS)
                .sourceIp(incident.getSrcIp()).reasonCode("TICKET_CLOSED"));
        audits.save(new AuditLog(event, actor.type(), actor.memberId(), null));
    }

    private static Severity max(Severity a, Severity b) {
        return a.compareTo(b) >= 0 ? a : b;
    }

    /** 모은 이벤트 중 가장 높은 심각도. INFO 는 티켓에서 LOW 로 본다. */
    private static Severity worstOf(List<SecurityEventEntity> collected) {
        Severity worst = Severity.LOW;
        for (SecurityEventEntity e : collected) if (e.getSeverity().compareTo(worst) > 0) worst = e.getSeverity();
        return worst;
    }

    private record Summary(String text, String actions) {}

    private static Summary summarize(String srcIp, List<SecurityEventEntity> collected, Severity worst) {
        Map<String, Long> byType = collected.stream().collect(Collectors.groupingBy(e -> e.getEventType().name(), java.util.TreeMap::new, Collectors.counting()));
        Set<String> actions = new TreeSet<>();
        for (SecurityEventEntity e : collected) if (RESPONSE_TYPES.contains(e.getEventType())) actions.add(e.getEventType().name());
        String actionText = actions.isEmpty() ? "없음" : String.join(", ", actions);
        String first = collected.isEmpty() ? "-" : kst(collected.getLast().getOccurredAt());
        String last = collected.isEmpty() ? "-" : kst(collected.getFirst().getOccurredAt());
        StringBuilder sb = new StringBuilder();
        sb.append("[인시던트 요약] 출발지 ").append(srcIp).append('\n');
        sb.append("- 관련 이벤트: ").append(collected.size()).append("건 (")
                .append(byType.entrySet().stream().map(e -> e.getKey() + "×" + e.getValue()).collect(Collectors.joining(", "))).append(")\n");
        sb.append("- 최초/최종(KST): ").append(first).append(" ~ ").append(last).append('\n');
        sb.append("- 취해진 조치: ").append(actionText).append('\n');
        sb.append("- 최고 심각도: ").append(worst).append('\n');
        sb.append("[타임라인]\n");
        collected.stream().limit(TIMELINE_LINES).forEach(e -> sb.append("- ").append(kst(e.getOccurredAt())).append(" [").append(e.getSeverity()).append('/')
                .append(e.getEventType()).append("] ").append(e.getReasonCode() == null ? "" : e.getReasonCode())
                .append(e.getMemberId() == null ? "" : " (회원 #" + e.getMemberId() + ")").append('\n'));
        String actionsColumn = actionText.length() > 255 ? actionText.substring(0, 255) : actionText;
        return new Summary(sb.toString().stripTrailing(), actionsColumn);
    }

    private static String kst(LocalDateTime utc) {
        return utc.atZone(ZoneOffset.UTC).withZoneSameInstant(KST).format(TIME);
    }
}
