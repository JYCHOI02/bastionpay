# 🎯 BastionPay 보안 이벤트 트리거 가이드

**Kali Linux(WSL)** 에서 BastionPay 웹(`https://192.168.3.12:8080`)에 **실제 요청을 보내** 보안 이벤트를 만들고, Graylog 탐지와 n8n 자동 대응을 검증하는 실행 매뉴얼입니다.

> Graylog에 로그를 직접 넣는 GELF 주입은 쓰지 않습니다. 모든 이벤트는 웹 앱이 직접 기록한 것만 쓰고, 경로는 아래와 같습니다.
> 웹 앱 → `logs/security-events.jsonl` → Filebeat → Graylog(5044) → 이벤트 정의 → n8n

---

## 📌 0. 환경 정보

| 구성 요소 | 주소 | 비고 |
|---|---|---|
| **BastionPay 웹 서버** | `https://192.168.3.12:8080` | Spring Boot (HTTPS) |
| **Graylog** | `http://192.168.3.12:9000` | Beats 입력 5044 (Filebeat) |
| **n8n SOAR** | `http://192.168.3.12:5678` | Security Alert Intake 워크플로 |
| **모의 공격 PC** | Kali Linux (WSL) | 트리거 실행 환경 |

사용하는 테스트 계정(`db/seed/README.md`의 개발용 공개 값, 비밀번호 `12345678A!`)

| 계정 | 쓰임 |
|---|---|
| `test@test.com` | 1번: 반복 실패로 잠기는 계정 |
| `vip@test.com` | 3·5번: 이체하는 회원, 4번: 관리자 페이지에 무단 접근하는 일반 회원 |
| `admin@test.com` | 복구: 잠금 해제, 차단 IP 해제, 티켓 종료 |

---

## 🚀 1. 실행 준비

```cmd
wsl.exe -d kali-linux -u root
```

```bash
cd /mnt/c/Users/user/Desktop/ALEPH/git_folder/project_potpolio/cjy/attack_trigger
chmod +x bastionpay_targeted_triggers.sh
```

**3·5번(이체) 사전 준비 — 한 번만**
1. MockBank 서버(8090)와 `mockbank-test.sql` 시드가 있어야 합니다(해지 계좌 `4001000000206`이 이 시드에 있음).
2. 브라우저에서 `vip@test.com`으로 로그인 → **은행 연결**(`/connect`) → 휴대폰 `010-0000-0003` → 인증번호 입력 → 계좌 선택 → 동의
3. 대시보드에 계좌가 보이면 완료. 연결은 계속 유지됩니다.

**출발지 IP에 대해**
1~6·4-1은 실제 요청이라, 출발지 IP는 앱이 연결에서 보는 **실제 접속 IP**로 기록됩니다. Kali(WSL) → `192.168.3.12:8080` 환경에서는 모두 `192.168.3.12`로 남고, 같은 IP라 티켓이 하나로 합쳐집니다. 4-2(K6-B)만 Graylog 모의 로그라 `192.168.3.207`로 따로 기록됩니다.

---

## 🎮 2. 실행 방법

```bash
./bastionpay_targeted_triggers.sh        # 번호 선택 메뉴 (Q 를 누를 때까지 계속 반복)
./bastionpay_targeted_triggers.sh 1      # 1번만 실행하고 종료
./bastionpay_targeted_triggers.sh 4b     # K6-B(탈취 성공)만 실행하고 종료
./bastionpay_targeted_triggers.sh all    # 전체 (1 → 2 → 6 → 3 → 5 → 4a) 실행하고 종료
```

메뉴 모드에서는 트리거 하나가 끝나면 다시 메뉴가 나옵니다. 끝내려면 `Q`(또는 Ctrl+C)를 누르세요.

**4번(ADMIN 권한 공격)은 세부 메뉴가 뜹니다.**
- `4` 선택 → `1` = 권한 탈취 **시도**(P4a / K6-A), `2` = 권한 승급 **탈취 성공**(P4b / K6-B)
- 인자로는 `4`(또는 `4a`)=시도, `4b`=탈취 성공

`all`은 4번 중 **시도(P4a)만** 실행합니다. 탈취 성공(P4b)은 실제 관리자 권한을 회수하므로 자동 전체 실행에서 빼고, 메뉴에서 직접 고르게 했습니다. P4a를 맨 마지막에 두는 이유는 그 실행으로 **공격 출발지 IP가 차단**되어 뒤 요청이 403이 되기 때문입니다.

---

## 🔍 3. 트리거 상세

| 번호 | 시나리오 | 실제로 보내는 요청 | 앱이 남기는 이벤트 | 기대 결과 |
|:---:|---|---|---|---|
| **1** | 반복 로그인 실패 | `test@test.com`에 틀린 비밀번호로 4초 간격 5회 로그인 | `LOGIN_FAILURE` 5건 + `ACCOUNT_LOCKED` 1건 | `S1`, `K2` 탐지 → 티켓 + Discord |
| **2** | 다중 계정 실패 | 같은 IP에서 서로 다른 계정 5개로 로그인 실패 | `LOGIN_FAILURE` 5건 (계정 해시가 서로 다름) | `L2` 탐지 → 검토 티켓 |
| **3** | 반복 이체 실패·환불 | `vip@test.com`으로 해지 계좌(한빛은행 `4001000000206`)에 10,000원 이체 2회 | `TRANSFER_REQUESTED` 2건 + `TRANSFER_REFUNDED` 2건 | `S3`(+`S2`) 탐지 → 티켓. 환불되므로 잔액 변화 없음 |
| **4-1** | 권한 탈취 **시도** (P4a / K6-A) | `vip@test.com`으로 로그인 후 `/admin/security` 접근 (실제 요청) | `ACCESS_DENIED` / `INSUFFICIENT_AUTHORITY` | HIGH 티켓 + **출발지 IP 차단** |
| **4-2** | 권한 승급 **탈취 성공** (P4b / K6-B) | **모의 로그 주입** — Graylog GELF(12201)로 `TIER_CHANGED`(reason `MALICIOUS_ADMIN_HIJACK`, member 2 = `test@test.com`) 1건 | (앱 로그 아님, Graylog 전용) | CRITICAL 티켓 + **Telegram** + SOAR **계정 잠금** (권한 회수는 '회수 불필요'로 넘어감) |
| **5** | 동일 계정 이체 요청 급증 | `vip@test.com`으로 한빛은행 `1002345678901`(테스터)에 1,000원 이체 5회 | `TRANSFER_REQUESTED` 5건 | `동일 계정 이체 요청 급증` 탐지. **실제 이체라 잔액이 5,000원 줄어듦** |
| **6** | 서버 API 인증 실패 | 잘못된 `X-API-Key`로 `GET /api/admin/incidents` 4회 | `API_AUTH_FAILED` 4건 | 티켓 없이 Discord **[운영자 알림]**만 |

### 4-2(K6-B)만 모의 로그인 이유
앱은 `TIER_CHANGED`를 정상 사유(`PROMOTED_BY_VOLUME`, `DEMOTED_INACTIVE`)로만 기록해서, "공격으로 인한 비정상 승급"을 실제로 만들 수 없습니다. 그래서 **"공격자가 이미 내부를 장악했다"고 가정**하고, 그 결과로 남을 `TIER_CHANGED` 로그를 Graylog에 직접 주입합니다. `_filebeat_app_name`·`_filebeat_event_source`를 함께 넣어 `BastionPay Security Events` 스트림으로 들어가므로, P4b 이벤트 정의가 이 로그를 탐지합니다. 모의 로그에는 `_mock_injection:true`가 붙어 실제 앱 로그와 구별됩니다.

> **4-2 대상은 `member_id=2`(test@test.com)입니다.** 이 계정은 ADMIN이 아니라 n8n의 **권한 회수는 "회수 불필요"로 넘어가고, 계정 잠금만 실제로 적용**됩니다. test@test.com은 잠금 allowlist에 있어 잠긴 뒤 관리자 화면에서 바로 해제할 수 있습니다(admin 계정은 전혀 건드리지 않음).
> 선행 조건: Graylog GELF 입력(12201)이 열려 있어야 하고, Kali에 `nc` 또는 `python3`가 있어야 합니다(둘 다 없으면 `/dev/udp` 사용).
> 권한 회수까지 실제로 보이게 하려면 대상을 시험용 ADMIN(`overpriv@test.com`, id 14)으로 바꾸면 됩니다. 스크립트 상단 `HIJACK_MEMBER_ID`를 `14`로 두고, 복구는 `db/seed/test-data.sql` 재실행으로 ADMIN 권한이 돌아옵니다. (`overpriv`는 잠금 허용 목록 밖이라 계정 잠금은 "잠글 수 없는 계정"으로 거절됩니다.)

---

## ✅ 4. 확인 방법

| 단계 | 어디서 | 무엇을 |
|---|---|---|
| 로그 수집 | Graylog Search, 스트림 `BastionPay Security Events` | `filebeat_app_name:bastionpay` 로 위 표의 이벤트가 들어왔는지 |
| 탐지 | Graylog **Alerts** | 해당 이벤트 정의의 경보 (실행 주기 때문에 최대 1~5분 지연) |
| 자동 대응 | n8n **Executions** | `BastionPay - Security Alert Intake` 실행 기록 |
| 결과 | 웹 관리자 화면 | 인시던트 티켓, 차단 IP, 잠금 계정 |

---

## 🧹 5. 복구 (상태 초기화)

관리자 계정은 **공격 출발지와 다른 주소**로 접속해야 합니다. 예: 이 PC 브라우저에서 `https://localhost:8080`. 공격 IP가 차단돼도 영향을 받지 않습니다.

| 트리거 후 | 복구 |
|---|---|
| 1번 | 관리자 → **잠금 계정**에서 `test@test.com` 잠금 해제 (또는 15분 뒤 자동 해제) |
| 4-1 | 관리자 → **차단 IP**에서 공격 출발지 IP(실제 접속 IP, 예: 192.168.3.12) 해제 |
| 4-2 | 관리자 → **잠금 계정**에서 `test@test.com` 잠금 해제 (1번과 동일) |
| 5번 | 줄어든 MockBank 잔액을 되돌리려면 `mock-openbanking/db/seed/mockbank-test.sql` 다시 실행 (계좌 연결은 BastionPay DB에 있어서 유지됨) |
| 공통 | 관리자 → **인시던트 티켓**에서 시험으로 생긴 티켓 종료 |
