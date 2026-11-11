# BastionPay 웹서버 실행 가이드

> 웹 앱(BastionPay, HTTPS 8080)과 모의 은행(MockBank, 8090)을 한 PC에서 띄우는 순서입니다.
> 근거 자료: [README.md](../../README.md), [db/seed/README.md](../../db/seed/README.md), [mock-openbanking/README.md](../../mock-openbanking/README.md), `src/main/resources/application*.yaml`

---

## 0. 구성

| 구성 요소 | 주소 | 실행 방법 |
|---|---|---|
| BastionPay 웹 | `https://localhost:8080` (다른 PC: `https://192.168.3.12:8080`) | IntelliJ 또는 `gradlew bootRun` |
| 웹 DB (MySQL) | `localhost:3306` / DB `bastionpay_db` | `docker/docker-compose.yml` (컨테이너 `mysql-server`) |
| MockBank 은행 서버 | `http://localhost:8090` | `mock-openbanking` 폴더에서 `gradlew bootRun` |
| MockBank DB (MySQL) | `127.0.0.1:3307` / DB `mockbank_db` | `mockbank-mysql/docker-compose.yml` (컨테이너 `mockbank-mysql`) |

**필요한 것**: Java 21 (JDK), Docker Desktop, IntelliJ IDEA(선택)

**실행 순서**: DB 2개 → 환경 파일 → 인증서 → MockBank → 웹 → 테스트 데이터

---

## 1. DB 띄우기

### 1-1. 웹 DB (3306)
```bash
cd docker
copy .env.example .env
```
`docker/.env`에 root 비밀번호를 넣고 실행합니다.
```
MYSQL_ROOT_PASSWORD=원하는-root-비밀번호
```
```bash
docker compose up -d
```

### 1-2. 웹 DB 계정 만들기 (처음 한 번만)
웹 DB는 MockBank와 달리 계정을 자동으로 만들지 않습니다. 앱 계정(데이터 읽기·쓰기)과 마이그레이션 계정(테이블 생성)을 나눠서 직접 만듭니다. 비밀번호는 2단계의 `.env`에 넣을 값과 같아야 합니다.
```bash
docker exec -it mysql-server mysql -uroot -p
```
```sql
CREATE USER 'bastionpay_app'@'%' IDENTIFIED BY '앱-계정-비밀번호';
GRANT SELECT, INSERT, UPDATE, DELETE ON bastionpay_db.* TO 'bastionpay_app'@'%';

CREATE USER 'bastionpay_migrator'@'%' IDENTIFIED BY '마이그레이션-계정-비밀번호';
GRANT ALL PRIVILEGES ON bastionpay_db.* TO 'bastionpay_migrator'@'%';
FLUSH PRIVILEGES;
```

### 1-3. MockBank DB (3307)
```bash
cd mockbank-mysql
copy .env.example .env
```
`mockbank-mysql/.env`에 비밀번호 3개를 정해서 넣고 실행합니다. 앱 계정과 마이그레이션 계정은 데이터 볼륨을 처음 만들 때 `init/01-users.sh`가 자동으로 만듭니다.
```
MOCKBANK_DB_ROOT_PASSWORD=...
MOCKBANK_DB_PASSWORD=...
MOCKBANK_DB_MIGRATION_PASSWORD=...
```
```bash
docker compose up -d
```

확인:
```bash
docker ps
```
`mysql-server`(0.0.0.0:3306)와 `mockbank-mysql`(127.0.0.1:3307)이 `Up`이면 됩니다.

---

## 2. 환경 파일 (.env)

### 2-1. 웹 (프로젝트 루트 `.env`)
```bash
copy .env.example .env
```
`application.yaml`이 루트의 `.env`를 자동으로 읽습니다(`spring.config.import: optional:file:.env`). 그래서 **작업 폴더가 프로젝트 루트여야** 합니다.

| 키 | 값 | 설명 |
|---|---|---|
| `DB_USERNAME` / `DB_PASSWORD` | `bastionpay_app` / 1-2에서 정한 값 | 앱 DB 계정 |
| `DB_MIGRATION_USERNAME` / `DB_MIGRATION_PASSWORD` | `bastionpay_migrator` / 1-2에서 정한 값 | Flyway 테이블 생성 계정 |
| `JWT_SECRET` | 32바이트 이상 무작위 문자열 | 로그인 토큰 서명 키 |
| `OPENBANKING_BASE_URL` | `http://localhost:8090/` | MockBank 주소 |
| `OPENBANKING_CLIENT_ID` | `bastionpay-dev-client` | MockBank 개발용 공개 값 |
| `OPENBANKING_CLIENT_SECRET` | `bastionpay-dev-secret` | 〃 |
| `OPENBANKING_ORG_CODE` | `M202610001` | 〃 |
| `OPENBANKING_PASS_PHRASE` | `bastionpay-dev-pass` | 〃 (입금이체 암호문구) |
| `SERVER_ADDRESS` | `0.0.0.0` | 다른 PC(Kali 등)에서도 접속하려면. 비우면 `127.0.0.1`만 |
| `SERVER_PORT` | `8080` | |
| `SECURITY_API_KEY` | 긴 무작위 문자열 | n8n이 `/api/admin/**`를 호출할 때 쓰는 키. 비우면 관리자 API가 항상 401 |
| `MAIL_USERNAME` / `MAIL_PASSWORD` | (선택) Gmail 앱 비밀번호 | 비우면 가입 인증 코드가 콘솔 로그에 출력됨 |

선택 항목(비우면 기본값):

| 키 | 기본값 | 설명 |
|---|---|---|
| `ADMIN_ALLOWLIST` | `admin@test.com` | 정상 관리자 이메일. 이 밖의 ADMIN은 "과잉권한"으로 표시 |
| `LOCKOUT_ALLOWLIST` | `test@test.com,vip@test.com,vvip@test.com` | 로그인 5회 실패 시 자동 잠금 대상 |
| `SECURITY_EVENT_LOG_FILE` | `logs/security-events.jsonl` | Filebeat·Wazuh가 읽는 보안 이벤트 파일 |
| `DEV_HTTPS` | `true` | `false`면 인증서 없이 http로 실행 |

### 2-2. MockBank (`mock-openbanking/.env`)
```bash
cd mock-openbanking
copy .env.example .env
```
`MOCKBANK_DB_PASSWORD`, `MOCKBANK_DB_MIGRATION_PASSWORD`를 **1-3의 `mockbank-mysql/.env`와 같은 값**으로 넣습니다. root 비밀번호는 넣지 않습니다.

---

## 3. 개발용 HTTPS 인증서 (`config/local-dev.p12`)

웹은 기본으로 HTTPS로 뜹니다(오픈뱅킹 콜백이 https라서). 인증서 파일은 `.gitignore` 대상이라 직접 만들어야 합니다. 다른 PC나 n8n에서도 접속하려면 **SAN에 접속 주소를 넣어야** 인증서 오류가 나지 않습니다.

```bash
"C:\Program Files\Java\jdk-21.0.12.1\bin\keytool.exe" -genkeypair -alias bastionpay-local -keyalg RSA -keysize 2048 -validity 365 -dname "CN=localhost" -ext "SAN=dns:localhost,dns:host.docker.internal,ip:127.0.0.1,ip:192.168.3.12" -keystore config\local-dev.p12 -storetype PKCS12 -storepass changeit -keypass changeit
```

- 비밀번호 `changeit`과 alias `bastionpay-local`은 `application-dev.yaml`에 고정된 값입니다.
- n8n 컨테이너가 이 인증서를 신뢰하게 하려면 공개 인증서를 내보내 n8n이 읽는 위치(`C:\n8n-certs\root-ca.crt`)에 넣고 n8n을 재시작합니다.
  ```bash
  "C:\Program Files\Java\jdk-21.0.12.1\bin\keytool.exe" -exportcert -rfc -alias bastionpay-local -keystore config\local-dev.p12 -storetype PKCS12 -storepass changeit -file C:\n8n-certs\root-ca.crt
  ```
  ```bash
  docker restart n8n
  ```
- 인증서 없이 띄우려면 `.env`에 `DEV_HTTPS=false`를 넣습니다. 이 경우 오픈뱅킹 계좌 연결(https 콜백)은 동작하지 않습니다.

---

## 4. MockBank 실행 (8090)

```bash
cd mock-openbanking
gradlew.bat bootRun
```
처음 실행하면 Flyway가 `mockbank_db`에 테이블을 만듭니다. `Started MockOpenBankingApplication`이 나오면 됩니다. `http://localhost:8090/`이 404를 돌려주면 정상입니다(루트 경로가 없음).

---

## 5. 웹 실행 (8080)

### 방법 A. IntelliJ (개발할 때)
1. 프로젝트 루트를 IntelliJ로 엽니다.
2. `src/main/java/com/san/bastionpay/BastionpayApplication.java`의 ▶ 실행
3. Run Configuration의 **Working directory가 프로젝트 루트**인지 확인합니다(`.env`, `config/local-dev.p12`, `logs/`를 이 위치 기준으로 찾음).
4. 프로필을 지정하지 않으면 `dev`로 뜹니다.

### 방법 B. Gradle
```bash
gradlew.bat bootRun
```

### 방법 C. 실행형 JAR (배포)
```bash
gradlew.bat bootJar
```
`build/libs/`에 생긴 JAR을 실행 폴더로 옮기고, 같은 폴더에 `.env`와 `config/local-dev.p12`를 함께 둡니다.
```bash
java -jar bastionpay-0.0.1-SNAPSHOT.jar
```
(JAR 이름은 `build/libs`에 생긴 파일명을 쓰세요.)

### 정상 기동 확인
로그에 아래가 나오면 됩니다.
```
Successfully validated 11 migrations
Tomcat started on port 8080 (https)
Started BastionpayApplication
```
- 브라우저에서 `https://localhost:8080` 접속 → 자체 서명 인증서 경고 → "고급 → 계속 진행"
- 포트가 떠 있는지:
  ```bash
  netstat -ano | findstr :8080
  ```

---

## 6. 테스트 데이터 넣기 (처음 한 번)

두 앱을 한 번 띄워 Flyway가 테이블을 만든 뒤에 넣습니다. 여러 번 넣어도 같은 결과가 됩니다.

```bash
docker cp db/seed/test-data.sql mysql-server:/tmp/test-data.sql
```
```bash
docker exec -it mysql-server sh -c "mysql -uroot -p bastionpay_db --default-character-set=utf8mb4 < /tmp/test-data.sql"
```
```bash
docker cp mock-openbanking/db/seed/mockbank-test.sql mockbank-mysql:/tmp/mockbank-test.sql
```
```bash
docker exec -it mockbank-mysql sh -c "mysql -uroot -p mockbank_db --default-character-set=utf8mb4 < /tmp/mockbank-test.sql"
```

테스트 계정(비밀번호 모두 `12345678A!`)

| 계정 | 역할 |
|---|---|
| `admin@test.com` | 관리자 (허용 목록 안) |
| `test@test.com`, `vip@test.com`, `vvip@test.com` | 일반 회원 (자동 잠금 대상) |
| `overpriv@test.com` | 허용 목록 밖 관리자 (과잉권한·권한 회수 시험용) |
| `locked@test.com` | 처음부터 잠긴 계정 (잠금 해제 시험용) |
| `review@test.com`, `volume@test.com`, `inactive@test.com` | 이체 검토·등급 승급·등급 강등 시험용 |

계정별 자세한 쓰임은 [db/seed/README.md](../../db/seed/README.md)를 참고하세요.

오픈뱅킹 계좌 연결은 회원으로 로그인 → **은행 연결**(`/connect`) → 휴대폰 번호(예: `vip@test.com` → `010-0000-0003`) → 화면에 뜨는 인증번호 입력 → 계좌 선택·동의 순서입니다. 연결은 `https://localhost:8080`으로 접속해서 하세요(콜백 주소가 접속 주소와 같아야 함).

---

## 7. 동작 확인

| 확인 | 방법 | 기대 결과 |
|---|---|---|
| 로그인 | `admin@test.com`으로 로그인 | `/admin/security` 보안 대시보드가 열림 |
| 보안 이벤트 기록 | 비밀번호를 일부러 틀림 | `logs/security-events.jsonl` 끝에 `LOGIN_FAILURE` 한 줄 추가 |
| 관리자 API | 잘못된 키로 호출 | 401 + `API_AUTH_FAILED` 기록 |
| 다른 PC 접속 | Kali에서 `curl -k https://192.168.3.12:8080/login` | 200 (안 되면 8장) |

관리자 API 확인 명령:
```bash
curl -k -s -o NUL -w "%{http_code}" https://localhost:8080/api/admin/incidents -H "X-API-Key: wrong"
```

---

## 8. 자주 생기는 문제

| 증상 | 원인 | 해결 |
|---|---|---|
| `Access denied for user 'bastionpay_app'` | DB 계정이 없거나 비밀번호가 `.env`와 다름 | 1-2 다시 확인 |
| `Validate failed: Migrations have failed validation` | 마이그레이션 파일이 바뀌어 체크섬이 다름 | 마이그레이션 파일을 되돌리거나, 개발 DB라면 볼륨을 지우고 다시 만듦 |
| 기동 시 `local-dev.p12` 관련 오류 | 인증서 파일이 없음 | 3장에서 만들거나 `DEV_HTTPS=false` |
| `Port 8080 was already in use` | 이미 실행 중인 웹이 있음 | `netstat -ano \| findstr :8080`으로 PID 확인 후 종료 |
| 계좌 연결 시 `invalid_grant` / redirect URI 오류 | 접속 주소와 콜백 주소가 다름, 또는 MockBank에 등록되지 않은 주소 | `https://localhost:8080`으로 접속해서 연결 |
| 다른 PC에서 접속이 안 됨 | `SERVER_ADDRESS`가 `127.0.0.1`이거나 Windows 방화벽이 8080을 막음 | `.env`에 `SERVER_ADDRESS=0.0.0.0`, 방화벽에 TCP 8080 인바운드 허용 |
| 모든 화면이 403 | 내 IP가 차단 목록에 있음 | 다른 주소(`localhost` ↔ `127.0.0.1`)로 관리자 로그인 → 차단 IP 해제 |
| n8n이 웹 API 호출 시 인증서 오류 | 인증서 SAN에 접속 주소가 없거나 n8n이 예전 인증서를 신뢰 | 3장대로 다시 발급하고 `root-ca.crt` 교체 후 `docker restart n8n` |
| 트리거 스크립트가 멈춤 | 웹이 꺼져 있음 | 5장의 정상 기동 로그 확인 |
| 이체가 "결과 확인 중"으로 멈춤 | MockBank(8090)가 꺼져 있음 | 4장 확인 |

---

## 9. 종료

- 웹·MockBank: IntelliJ ■ 또는 터미널에서 Ctrl+C
- DB: 각 폴더에서 `docker compose stop` (데이터는 볼륨에 남음). `docker compose down -v`는 **데이터까지 지우니** 주의
