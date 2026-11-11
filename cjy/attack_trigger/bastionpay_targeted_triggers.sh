#!/bin/bash
# ==============================================================================
# BastionPay 보안 이벤트 트리거 스크립트 (실제 요청만 사용)
# 웹 서버, Graylog, n8n 모두 192.168.3.12
#
# 모든 이벤트는 웹 앱에 실제 요청을 보내서 만든다. Graylog 에 로그를 직접 넣지 않는다.
#   웹 앱 → logs/security-events.jsonl → Filebeat → Graylog(5044) → 이벤트 정의 → n8n
# 3·5번(이체)은 NORMAL_USER 의 오픈뱅킹 계좌 연결이 한 번 되어 있어야 한다.
# K6-B 는 앱에서 공격으로 만들 수 없어 안내만 한다.
# ==============================================================================

WEB_HOST="https://192.168.3.12:8080"
GRAYLOG_HOST="192.168.3.12"        # K6-B 모의 로그 주입 대상 (GELF)
GRAYLOG_GELF_PORT="12201"

# 테스트 계정 (db/seed/README.md 의 개발용 공개 값)
LOCK_TARGET="test@test.com"        # 1번: 반복 실패로 잠기는 계정 (잠금 allowlist 대상)
NORMAL_USER="vip@test.com"         # 3·4·5번: 이체와 관리자 페이지 무단 접근에 쓰는 일반 회원
NORMAL_PW='12345678A!'
HIJACK_MEMBER_ID="2"               # K6-B '탈취된' 대상. test@test.com(id 2). 잠금 allowlist라 계정 잠금이 실제로 적용되고, 관리자 화면에서 바로 해제된다

# 실제 요청(1·2·3·4a·5·6)의 출발지 IP는 앱이 연결에서 보는 실제 IP(getRemoteAddr)로 기록된다.
# Kali(WSL) → 192.168.3.12:8080 환경에서는 모두 192.168.3.12 로 남는다.
# 4-2(K6-B)만 Graylog 모의 로그라 src_ip 를 직접 넣는다.
IP_T4B="192.168.3.207"            # 4-2 권한 승급 탈취 성공 (GELF 모의 로그)

echo "=========================================================="
echo " [BastionPay] 보안 이벤트 트리거 실행기 (실제 요청)"
echo "  - 대상 웹서버 : ${WEB_HOST}"
echo "=========================================================="

# 모든 요청은 이 함수로 보낸다. 서버가 꺼져 있거나 막혀 있으면 무한정 기다리지 않고 끊는다
http_req() {
    curl -k -s --connect-timeout 5 --max-time 20 "$@"
}

# 웹 서버가 응답하는지 확인한다. 응답이 없으면 0이 아닌 값을 돌려준다
check_web() {
    local code
    code=$(http_req -o /dev/null -w "%{http_code}" "${WEB_HOST}/login")
    if [ "$code" = "000" ]; then
        echo ""
        echo " [!] 웹 서버(${WEB_HOST})가 응답하지 않습니다."
        echo "     - 192.168.3.12 PC에서 BastionPay 앱이 실행 중인지 확인하세요 (IntelliJ 실행 / 8080 포트)"
        echo "     - 앱이 떠 있다면 Windows 방화벽의 TCP 8080 인바운드 허용을 확인하세요"
        return 1
    fi
    [ "$code" = "403" ] && echo " [!] 웹 서버가 403을 돌려줍니다. 이 PC의 IP가 차단됐을 수 있습니다(관리자 > 차단 IP 확인)."
    return 0
}

# Graylog 로 GELF(UDP) 한 줄을 보낸다. 인자: JSON 페이로드
# K6-B 전용. 앱은 TIER_CHANGED 를 정상 사유로만 기록하므로, '탈취 성공'은 모의 로그로만 재현한다
send_gelf() {
    local payload="$1"
    if command -v nc >/dev/null 2>&1; then
        printf '%s' "$payload" | nc -u -w1 "${GRAYLOG_HOST}" "${GRAYLOG_GELF_PORT}"
    elif command -v python3 >/dev/null 2>&1; then
        GL_HOST="$GRAYLOG_HOST" GL_PORT="$GRAYLOG_GELF_PORT" GL_MSG="$payload" python3 - <<'PY'
import os, socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(os.environ["GL_MSG"].encode("utf-8"), (os.environ["GL_HOST"], int(os.environ["GL_PORT"])))
s.close()
PY
    else
        printf '%s' "$payload" > "/dev/udp/${GRAYLOG_HOST}/${GRAYLOG_GELF_PORT}" 2>/dev/null
    fi
}

# 로그인 화면에서 CSRF 토큰을 받아 온다. 인자: 쿠키 파일
get_csrf() {
    http_req -c "$1" -b "$1" "${WEB_HOST}/login" | grep -o 'name="_csrf" value="[^"]*"' | sed 's/.*value="//;s/"//'
}

# 로그인 요청. 인자: 쿠키 파일, 이메일, 비밀번호. HTTP 코드를 출력한다
post_login() {
    local jar="$1" email="$2" pw="$3" csrf
    csrf=$(get_csrf "$jar")
    http_req -o /dev/null -w "%{http_code}" -b "$jar" -c "$jar" \
        -X POST "${WEB_HOST}/login" \
        --data-urlencode "email=${email}" \
        --data-urlencode "password=${pw}" \
        --data-urlencode "_csrf=${csrf}"
}

# 이체 요청 ID (UUID 소문자, 앱이 형식을 검사한다)
new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; return; fi
    local h; h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    echo "${h:0:8}-${h:8:4}-4${h:13:3}-a${h:17:3}-${h:20:12}"
}

# UTF-8 퍼센트 인코딩. 한글 은행 이름을 curl 에 그대로 넘기면 Windows(Git Bash)에서 깨지므로 직접 인코딩한다
urlencode() {
    local LC_ALL=C s="$1" out="" c h i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v h '%%%02X' "'$c"; out+="${h: -3}" ;;
        esac
    done
    echo "$out"
}

# 로그인된 쿠키로 이체 한 건을 실행한다. 인자: 쿠키 파일, 받는 은행, 받는 계좌, 금액
# 결과를 COMPLETED / REFUNDED / REVIEW / NO_ACCOUNT / ERROR:<사유> 중 하나로 출력한다
do_transfer() {
    local jar="$1" bank="$2" account="$3" amount="$4" page csrf from res
    page=$(http_req -b "$jar" -c "$jar" "${WEB_HOST}/transfer")
    from=$(echo "$page" | grep -o '<option value="[0-9]\{24\}"' | head -1 | grep -o '[0-9]\{24\}')
    if [ -z "$from" ]; then echo "NO_ACCOUNT"; return; fi
    csrf=$(echo "$page" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//')
    # 확인 화면(/transfer/confirm)은 건너뛴다. 실행 단계에서 서버가 모든 값을 다시 검증한다
    res=$(http_req -b "$jar" -c "$jar" -X POST "${WEB_HOST}/transfer/execute" \
        --data-urlencode "_csrf=${csrf}" \
        --data-urlencode "fromAccountId=${from}" \
        --data "toBank=$(urlencode "$bank")" \
        --data-urlencode "toAccount=${account}" \
        --data-urlencode "amount=${amount}" \
        --data-urlencode "memo=trigger" \
        --data-urlencode "requestId=$(new_uuid)")
    if echo "$res" | grep -q '출금된 금액은 내 계좌로 돌려드렸습니다'; then echo "REFUNDED"
    elif echo "$res" | grep -q '이체가 완료되었습니다'; then echo "COMPLETED"
    elif echo "$res" | grep -q '이체 결과를 확인하고 있습니다'; then echo "REVIEW"
    else echo "ERROR:$(echo "$res" | grep -o 'class="form-error" role="alert">[^<]*' | head -1 | sed 's/.*>//')"
    fi
}

# 이체용 회원으로 로그인한다. 실패하면 1 을 돌려준다. 인자: 쿠키 파일
login_transfer_user() {
    local code; code=$(post_login "$1" "$NORMAL_USER" "$NORMAL_PW")
    echo "   -> ${NORMAL_USER} 로그인 HTTP ${code} (302 기대)"
    [ "$code" = "302" ]
}

# ------------------------------------------------------------------------------
# 1. 반복 로그인 5회 실패 → S1, K2 (5번째 실패에서 ACCOUNT_LOCKED)
# ------------------------------------------------------------------------------
trigger_1_repeat_login_failure() {
    echo ""
    echo "[1] '반복 로그인 5회 실패' 트리거 시작..."
    echo " -> 20초 동안 4초 간격으로 같은 계정(${LOCK_TARGET}) 로그인 실패 5회"

    local jar; jar=$(mktemp)
    for i in {1..5}; do
        code=$(post_login "$jar" "$LOCK_TARGET" "WrongPassword123!")
        echo " [시도 $i/5] HTTP ${code} (401 기대)"
        [ "$i" -lt 5 ] && sleep 4
    done
    rm -f "$jar"
    echo " -> [완료] 앱 기록: LOGIN_FAILURE 5건 + ACCOUNT_LOCKED 1건"
    echo "    Graylog 'S1_반복 로그인 실패', 'K2_Hydra 로그인 브루트포스' 감지 대기"
    echo "    복구: 관리자 화면 > 잠금 계정에서 ${LOCK_TARGET} 잠금 해제"
}

# ------------------------------------------------------------------------------
# 2. 다중 계정 실패 → L2 (같은 IP, 서로 다른 계정 5개)
# ------------------------------------------------------------------------------
trigger_2_multi_account_failure() {
    echo ""
    echo "[2] '다중 계정 실패' 트리거 시작..."
    echo " -> 같은 IP에서 서로 다른 계정 5개로 로그인 실패"

    local jar; jar=$(mktemp)
    local accounts=("admin_test@test.com" "finance_mgr@test.com" "operator@test.com" "dev_lead@test.com" "vip_user@test.com")
    for i in "${!accounts[@]}"; do
        code=$(post_login "$jar" "${accounts[$i]}" "InvalidPassword999!")
        echo " [시도 $((i+1))/5] ${accounts[$i]} → HTTP ${code}"
        sleep 1
    done
    rm -f "$jar"
    echo " -> [완료] Graylog 'L2_동일 IP 다중 계정 로그인 실패' 감지 대기 (K2도 함께 잡힐 수 있음)"
}

# ------------------------------------------------------------------------------
# 3. 동일 출발지 반복 이체 실패·환불 → S3
#    해지 계좌로 이체 → 출금 후 입금 거절 → 앱이 환불(TRANSFER_REFUNDED). 잔액은 그대로 돌아온다
#    필요: ${NORMAL_USER} 의 오픈뱅킹 계좌 연결(한 번만), MockBank 서버(8090), mockbank-test.sql 시드
# ------------------------------------------------------------------------------
trigger_3_transfer_refund_burst() {
    echo ""
    echo "[3] '동일 출발지 반복 이체 실패·환불' 트리거 시작..."
    echo " -> 해지 계좌(한빛은행 4001000000206)로 10,000원 이체 2회"

    local jar; jar=$(mktemp)
    if ! login_transfer_user "$jar"; then
        echo "   -> 로그인 실패. 계정이 잠겼거나 IP가 차단됐는지 확인하세요."; rm -f "$jar"; return
    fi
    for i in 1 2; do
        result=$(do_transfer "$jar" "한빛은행" "4001000000206" 10000)
        echo " [이체 $i/2] 결과: ${result} (REFUNDED 기대)"
        if [ "$result" = "NO_ACCOUNT" ]; then
            echo "   -> 연결된 계좌가 없습니다. 브라우저에서 ${NORMAL_USER} 계좌를 먼저 연결하세요."; break
        fi
        sleep 2
    done
    rm -f "$jar"
    echo " -> [완료] 앱 기록: TRANSFER_REQUESTED + TRANSFER_REFUNDED(FAILURE) 2건"
    echo "    Graylog 'S3_동일 출발지 반복 이체 실패·환불' (+ 'S2_이체 실패 후 환불 완료') 감지 대기"
}

# ------------------------------------------------------------------------------
# 4-1. P4a(K6-A) ADMIN 권한 탈취 시도 — 실제 요청
# ------------------------------------------------------------------------------
trigger_4a_admin_attempt() {
    echo ""
    echo "[4-1] 'ADMIN 권한 탈취 시도 (P4a)' 트리거 시작..."
    echo " -> 일반 회원(${NORMAL_USER})으로 로그인한 뒤 관리자 페이지 접근"
    echo " ※ n8n 이 이 PC(공격 출발지) IP를 자동 차단합니다. 이후 요청은 403이 됩니다."

    local jar; jar=$(mktemp)
    code=$(post_login "$jar" "$NORMAL_USER" "$NORMAL_PW")
    echo "   -> 로그인 HTTP ${code} (302 기대)"
    if [ "$code" != "302" ]; then
        echo "   -> 로그인 실패. 계정이 잠겼거나 IP가 이미 차단됐는지 확인하세요."
        rm -f "$jar"; return
    fi
    code=$(http_req -o /dev/null -w "%{http_code}" -b "$jar" "${WEB_HOST}/admin/security")
    echo "   -> /admin/security HTTP ${code} (403 기대 → ACCESS_DENIED / INSUFFICIENT_AUTHORITY)"
    rm -f "$jar"
    echo " -> [완료] Graylog 'P4a_ADMIN 권한 탈취 시도 탐지' → HIGH 티켓 + IP 차단 대기"
    echo "    복구: 다른 주소(localhost)로 관리자 로그인 → 차단 IP 해제, 티켓 종료"
}

# ------------------------------------------------------------------------------
# 4-2. P4b(K6-B) 비정상 ADMIN 권한 승급 침해(탈취 성공) — 모의 로그 주입
#   앱은 TIER_CHANGED 를 정상 사유로만 기록해서 실제 공격으로는 만들 수 없다.
#   그래서 "공격자가 이미 ADMIN 권한을 얻었다"고 가정한 로그 1건을 Graylog GELF 입력으로 직접 보낸다.
#   - BastionPay 스트림으로 라우팅되도록 event_source·app_name 을 함께 넣는다(스트림 규칙과 일치)
#   - P4b 탐지 → CRITICAL 티켓 + Telegram + SOAR(권한 회수 + 계정 잠금)
# ------------------------------------------------------------------------------
trigger_4b_admin_takeover() {
    local src_ip="$IP_T4B"
    echo ""
    echo "[4-2] '비정상 ADMIN 권한 승급 침해 (P4b)' 트리거 시작..."
    echo " ※ 실제 공격이 아니라 '내부 장악 가정' 모의 로그를 Graylog(${GRAYLOG_HOST}:${GRAYLOG_GELF_PORT}/GELF)에 주입합니다."
    echo " -> TIER_CHANGED(reason=MALICIOUS_ADMIN_HIJACK) / 대상 member_id=${HIJACK_MEMBER_ID} / src_ip=${src_ip}"

    local payload
    payload=$(cat <<JSON
{"version":"1.1","host":"bastionpay","short_message":"[MOCK] Malicious ADMIN tier escalation","_filebeat_app_name":"bastionpay","_filebeat_event_source":"bastionpay_security","_filebeat_event_type":"TIER_CHANGED","_filebeat_reason_code":"MALICIOUS_ADMIN_HIJACK","_filebeat_source_ip":"${src_ip}","_filebeat_member_id":"${HIJACK_MEMBER_ID}","_filebeat_severity":"CRITICAL","_mock_injection":"true"}
JSON
)
    send_gelf "$payload"
    echo "   -> 모의 로그 주입 완료"
    echo " -> [완료] Graylog 'P4b_비정상 ADMIN 권한 승급 침해 탐지' 대기"
    echo "    예상 대응: CRITICAL 티켓 + Telegram + SOAR 권한 회수/계정 잠금 호출(member ${HIJACK_MEMBER_ID}=test@test.com)"
    echo "    ※ test@test.com 은 ADMIN 이 아니라 권한 회수는 '회수 불필요'로 넘어가고, 계정 잠금이 실제로 적용됩니다"
    echo "    복구: 관리자 화면 > 잠금 계정에서 test@test.com 잠금 해제"
}

# 4번 선택 시 세부 메뉴: 1=시도(P4a), 2=탈취 성공(P4b)
trigger_4_admin_privilege_abuse() {
    echo ""
    echo "  [4] ADMIN 권한 공격 — 세부 선택"
    echo "    1) 권한 탈취 '시도'       (P4a / K6-A, 실제 요청)"
    echo "    2) 권한 승급 '탈취 성공'  (P4b / K6-B, Graylog 모의 로그 주입)"
    read -rp "  선택 (1-2): " sub || { echo ""; return; }
    case "$sub" in
        1) trigger_4a_admin_attempt ;;
        2) trigger_4b_admin_takeover ;;
        *) echo "  잘못된 입력입니다." ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. 동일 계정 이체 요청 급증 → 같은 회원 5분 안에 이체 요청 5건
#    정상 계좌(한빛은행 1002345678901, 테스터)로 1,000원씩 실제 이체한다. 잔액이 5,000원 줄어든다
#    (시드 값으로 되돌리려면 mockbank.sql 다시 실행)
# ------------------------------------------------------------------------------
trigger_5_transfer_request_surge() {
    echo ""
    echo "[5] '동일 계정 이체 요청 급증' 트리거 시작..."
    echo " -> 같은 회원(${NORMAL_USER})으로 한빛은행 1002345678901 에 1,000원 이체 5회"

    local jar; jar=$(mktemp)
    if ! login_transfer_user "$jar"; then
        echo "   -> 로그인 실패. 계정이 잠겼거나 IP가 차단됐는지 확인하세요."; rm -f "$jar"; return
    fi
    for i in {1..5}; do
        result=$(do_transfer "$jar" "한빛은행" "1002345678901" 1000)
        echo " [이체 $i/5] 결과: ${result} (COMPLETED 기대)"
        if [ "$result" = "NO_ACCOUNT" ]; then
            echo "   -> 연결된 계좌가 없습니다. 브라우저에서 ${NORMAL_USER} 계좌를 먼저 연결하세요."; break
        fi
        sleep 2
    done
    rm -f "$jar"
    echo " -> [완료] 앱 기록: TRANSFER_REQUESTED 5건 → Graylog '동일 계정 이체 요청 급증' 감지 대기"
}

# ------------------------------------------------------------------------------
# 6. 서버 API 인증 실패 (잘못된 API 키로 4회) → 운영자 알림만, 티켓 없음
# ------------------------------------------------------------------------------
trigger_6_api_auth_failed() {
    echo ""
    echo "[6] '서버 API 인증 실패' 트리거 시작..."
    echo " -> 잘못된 API 키로 관리자 API(GET /api/admin/incidents) 4회 호출"

    for i in {1..4}; do
        code=$(http_req -o /dev/null -w "%{http_code}" \
            "${WEB_HOST}/api/admin/incidents" \
            -H "X-API-Key: ATTACKER_BAD_KEY_12345")
        echo " [호출 $i/4] HTTP ${code} (401 기대 → API_AUTH_FAILED)"
        sleep 1
    done
    echo " -> [완료] Graylog '서버 API 인증 실패' 감지 → Discord [운영자 알림]만 발송되는지 확인"
}

# 자동 실행(비대화형). 4번은 '시도'(P4a)만 실행한다. '탈취 성공'(P4b)은 실제 관리자 권한을
# 회수하므로 자동 전체 실행에 넣지 않고, 메뉴에서 직접 고르게 한다. P4a 는 IP를 차단하므로 맨 마지막
run_all() {
    trigger_1_repeat_login_failure; sleep 2
    trigger_2_multi_account_failure; sleep 2
    trigger_6_api_auth_failed; sleep 2
    trigger_3_transfer_refund_burst; sleep 2
    trigger_5_transfer_request_surge; sleep 2
    trigger_4a_admin_attempt
    echo ""
    echo "전체 트리거(1 → 2 → 6 → 3 → 5 → 4a) 실행 완료."
    echo "P4b(권한 탈취 성공)는 메뉴에서 '4 → 2' 로 직접 실행하세요."
}

# ------------------------------------------------------------------------------
# 메뉴 실행기
# ------------------------------------------------------------------------------
show_menu() {
    echo ""
    echo "----------------------------------------------------------"
    echo " 실행할 트리거 번호를 선택하세요:"
    echo "  1) 반복 로그인 5회 실패 (20초간 분산 요청)"
    echo "  2) 다중 계정 실패 (동일 IP 5개 계정)"
    echo "  3) 동일 출발지 반복 이체 실패·환불 (해지 계좌로 2회)"
    echo "  4) ADMIN 권한 공격 → 1.시도(P4a)  2.탈취 성공(P4b, 모의 로그)"
    echo "  5) 동일 계정 이체 요청 급증 (1,000원 x 5회)"
    echo "  6) 서버 API 인증 실패 (4회)"
    echo "  A) 전체 실행 (1 → 2 → 6 → 3 → 5 → 4)"
    echo "  Q) 종료"
    echo "----------------------------------------------------------"
    # 입력이 끝나면(Ctrl+D) 종료
    read -rp "선택 (1-6, A, Q): " choice || { echo ""; echo "종료합니다."; exit 0; }
    case "$choice" in
        1) trigger_1_repeat_login_failure ;;
        2) trigger_2_multi_account_failure ;;
        3) trigger_3_transfer_refund_burst ;;
        4) trigger_4_admin_privilege_abuse ;;
        5) trigger_5_transfer_request_surge ;;
        6) trigger_6_api_auth_failed ;;
        A|a) run_all ;;
        Q|q) echo "종료합니다."; exit 0 ;;
        *) echo "잘못된 입력입니다." ;;
    esac
}

# 인자가 전달되면 해당 트리거만 실행하고 끝낸다. 없으면 Q 를 누를 때까지 메뉴를 반복한다
if [ -n "$1" ]; then
    case "$1" in
        1) trigger_1_repeat_login_failure ;;
        2) trigger_2_multi_account_failure ;;
        3) trigger_3_transfer_refund_burst ;;
        4|4a) trigger_4a_admin_attempt ;;
        4b) trigger_4b_admin_takeover ;;
        5) trigger_5_transfer_request_surge ;;
        6) trigger_6_api_auth_failed ;;
        all|A|a) run_all ;;
        *) echo "사용법: $0 [1|2|3|4|4a|4b|5|6|all]  (4=시도, 4b=탈취 성공)" ;;
    esac
else
    while true; do
        show_menu
    done
fi
