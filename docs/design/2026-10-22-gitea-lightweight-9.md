---
title: "사내 Gitea 경량화 (9) — Gitea·Nexus·Runner 백업과 복구 체계 만들기"
summary: "별도 NAS 없이 다른 물리서버에 백업하는 운영 가이드다. 짧은 서비스 중단으로 일관된 복사본을 만들고, 매일 백업·기간별 보관·암호화 전송·Gitea DB와 Nexus 전체 복구 절차를 구성한다."
summary_style: editorial
date: 2026-10-22
category: 구축설계
tags:
  - OpenStack
  - Automation
  - Linux
  - 가이드
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">사내 Gitea 경량화 · 백업과 복구 편</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">코드와 TAR뿐 아니라, 다시 발행할 수 있는 운영 상태를 백업한다.</h2>
      <p>물리서버 한 대에 Gitea·Nexus·Runner가 함께 있으면 디스크 장애로 코드·설치 재료·승인 기록을 동시에 잃을 수 있다. NAS 대신 다른 물리서버에 암호화한 백업을 보관하고, 일관된 복사본을 만드는 동안만 서비스를 중단한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>매일 백업, 일간 7개·주간 4개·월간 3개 보관.</strong> Runner → Gitea·Nexus 순으로 멈추고, 서비스를 재개한 뒤 원격 전송한다.</span></p>
</section>

[8편](2026-10-22-gitea-lightweight-8.md)의 오래된 파일 정리는 디스크를 아끼는 정책이다. 백업은 그 반대 상황, 즉 **남아 있어야 할 파일과 설정을 잃었을 때**를 위한 정책이다. 고객사 반입 TAR 하나와 사내 서비스의 백업은 목적부터 다르다.

이 글은 Gitea + PostgreSQL, **내장 H2 DB를 사용하는 Nexus**, systemd host Runner를 위한 백업·복구 절차다. Nexus를 외부 PostgreSQL로 전환한 환경에는 H2 파일 복사 대신 해당 DB의 일관된 백업 절차가 필요하다.

## 1. Git 코드와 Nexus Blob만 있으면 복구할 수 있을까

일부는 가능하지만 운영 상태 전체는 돌아오지 않는다.

| 보관 대상 | 들어 있는 것 | 빠졌을 때 |
| --- | --- | --- |
| Gitea Git repositories | 코드, Workflow 파일, commit·branch·Tag | 개발·릴리스 코드 유실 |
| Gitea PostgreSQL | 사용자·권한, PR·승인, 보호 규칙, Release 설명, Actions 관련 DB 기록 | 코드는 있어도 승인·운영 이력 복원 불가 |
| Gitea 데이터·app.ini | 저장소, 첨부·LFS·로컬 저장 데이터, 암호화 키·설정 | DB만 복구해도 파일·비밀 해독에 문제 가능 |
| Nexus DB + Blob + 설정 | Repository·사용자·역할·메타데이터와 파일 본문 | Blob만으로 기존 경로·권한·상태를 온전히 복구할 수 없음 |
| Runner·빌더·HAProxy | 실행 등록, 키, 통합 설정, 스크립트·템플릿, 채널 map | 저장소가 살아도 패키징·고정 다운로드 주소는 동작하지 않을 수 있음 |
| OpenTofu 설정·State | 시험 환경 정의, 관리 중인 자원과 실제 ID | 남은 시험 자원 확인·정리 어려움 |

Workflow YAML은 Git 안에 있다. 반면 **Gitea UI에서 등록한 Secret·브랜치 규칙·PR 승인·Release 본문은 Git clone에 포함되지 않는다.** DB와 암호화 키를 함께 복구해야 한다. Actions 로그·첨부·패키지 등을 외부 객체 저장소로 분리했다면 그 저장소도 별도로 백업한다.

Nexus는 H2의 `db/`와 대응 Blob, 설정, `keystores/node/`를 같은 복구 시점으로 맞춘다. 이 구성에서는 일부 폴더를 골라 맞추기보다 **정지 상태의 nexus-data 전체**를 보관하는 편이 단순하다. [Sonatype Prepare a Backup](https://help.sonatype.com/en/prepare-a-backup.html), [H2 백업·복구](https://help.sonatype.com/en/configure-and-run-the-backup-task.html)

!!! tip "무엇을 제외해도 되는가"
    다시 받을 수 있는 Raw 캐시·containerd 캐시, 게시 후 삭제하는 로컬 TAR, Runner workspace와 `.tfplan`은 기본 백업에서 제외한다. 원본 아티팩트와 최종 TAR는 Nexus 백업에 들어간다. OpenTofu State는 캐시가 아니므로 제외하지 않는다.

---

## 2. 중단은 최종 복사 동안만, 전송은 서비스 재개 후

Gitea는 DB·파일·Git 저장소가 함께 바뀐다. DB를 온라인 dump할 수 있다는 사실만으로 세 영역의 시점이 같아지지는 않는다. 공식 문서도 일관된 전체 백업을 위해 Gitea 정지를 안내한다. [Gitea Backup Consistency](https://docs.gitea.com/1.25/administration/backup-and-restore/#backup-consistency)

Nexus H2 파일도 실행 중 일반 파일처럼 복사하지 않는다. 다음 흐름으로 **쓰기 작업을 멈춘 최종 복사본**을 만든다.

<figure class="flow" aria-label="서비스 중단을 최종 동기화 구간으로 제한한 백업">
  <ol>
    <li>가동 중 사전 복사</li>
    <li>Runner 종료 대기</li>
    <li>Gitea·Nexus 정지</li>
    <li>최종 동기화·DB dump</li>
    <li>서비스 재개</li>
    <li>다른 서버로 전송</li>
  </ol>
</figure>

| 구간 | 서비스 상태 | 의미 |
| --- | --- | --- |
| 사전 복사 | 사용 가능 | 큰 파일을 먼저 복사. 아직 유효한 백업은 아님 |
| Runner 종료 대기 | Gitea·Nexus 사용 가능 | 새 CI 수신을 멈추고 실행 중 작업이 끝나도록 기다림 |
| 최종 동기화 | Gitea·Nexus 일시 중단 | Nexus DB·Blob 및 Gitea 파일·DB의 일관된 복사본 확보 |
| 암호화 원격 전송 | 서비스 재개 | 고정된 로컬 복사본을 다른 물리서버에 보관 |

Gitea만 멈추고 PostgreSQL 컨테이너는 실행해 둔다. Gitea의 쓰기가 멈춘 상태에서 `pg_dump`를 실행한다. Nexus는 완전히 정지한 뒤 H2를 포함해 최종 동기화한다. [PostgreSQL SQL Dump](https://www.postgresql.org/docs/14/backup-dump.html)

사전 복사를 해도 최종 동기화·DB dump·재기동 시간은 남는다. “무중단”이나 고정된 몇 초를 약속하는 구성이 아니다. 첫 백업에서 실제 중단 시간을 재고 유지보수 창을 잡는다. Nexus Cleanup·compact·수동 설정 변경은 이 구간과 겹치지 않게 한다.

중단 중에는 Gitea 웹·Git 접근과 Nexus 다운로드가 잠시 불가능하다. 진행 중인 큰 다운로드도 끊길 수 있으므로 팀과 사업수행팀에 유지보수 시간을 공지한다.

---

## 3. 백업 서버와 주기 정하기

백업 서버는 운영 서버와 **다른 물리서버·다른 디스크**를 사용한다. 같은 서버의 `/backup` 디렉터리나 다른 파티션만으로 끝내지 않는다.

| 항목 | 시작 정책 |
| --- | --- |
| 전체 서비스 백업 | 매일 01:00, 팀의 비업무 유지보수 시간 |
| 수동 백업 | 서비스 업그레이드·대규모 설정 변경 직전, 중요 릴리스 확정 후 |
| 보관 | 일간 7개 + 주간 4개 + 월간 3개 |
| 백업 구조 확인 | 주 1회 |
| 데이터 일부 읽기 검사 | 월 1회 |
| 별도 서버 복구 연습 | 분기 1회, 첫 구축·중요 구성 변경 후에도 수행 |
| 백업 실패 확인 | 다음 업무 시작 전 성공 로그·원격 snapshot 확인 |

일·주·월 보관 조건은 서로 겹칠 수 있어 정확히 14벌을 별도 복사한다는 뜻은 아니다. **일간은 최근 백업이 있는 7일의 대표본**이다. 며칠 실패했다고 그 공백이 자동 보완되지는 않는다.

매일 백업이 성공한다면 장애 시 최대 하루가량의 변경을 잃을 수 있다. 이 허용 손실을 RPO라고 한다. 백업이 연속 실패하면 손실 구간도 늘어난다. 실제 복구 소요 시간인 RTO는 복구 연습에서 측정한다. 릴리스 직후 손실을 줄이려면 정기 백업 외에 수동 백업을 추가한다.

대용량 파일 전체를 날짜별 TAR로 매일 복사하는 대신 **Restic**을 사용한다. Restic은 백업을 암호화하고 이미 저장한 데이터 조각을 재사용하는 도구다. 전송은 SFTP, 저장 대상은 다른 물리서버의 디렉터리다. [Restic 저장소와 SFTP](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#sftp)

```text title="백업은 두 저장 공간을 사용한다"
운영 서버
  /data/release-service-backup/staging/   정지 시점으로 맞춘 작업용 복사본
                │
                └── 암호화·중복 제거·SFTP 전송
                                 ↓
다른 물리서버
  /srv/backup/release-services/          Restic 저장소, 여러 시점의 snapshot
```

로컬 staging은 서비스 재개 후에도 원격 전송이 끝날 때까지 유지한다. 원본과 staging을 함께 둘 디스크가 필요하다. Restic의 중복 제거는 **백업 서버 공간·전송량**에 적용되며 로컬 staging 복사본을 없애는 기능은 아니다. 원본이 계속 늘면 백업 디스크도 늘어난다.

---

## 4. 처음 한 번 준비할 파일과 백업 명령

아래는 운영 서버 root와 별도 백업 서버에서 구성하는 예시다. 경로·사용자·인증서·컨테이너 이름을 자신의 Compose와 맞춘 뒤 적용한다. 기존 데이터가 있는 서버에서 복구 명령을 시험하지 않는다.

<p class="subsection-title"><strong>4-1. Restic과 백업 전용 SSH 준비</strong></p>

<div class="section-body" markdown="1">

운영 서버에는 `restic`, `rsync`, GNU tar가 필요하다. 백업 서버에는 SSH/SFTP와 저장 디스크가 필요하며 Restic 서버 데몬은 필요 없다. Ubuntu/Debian 예시는 다음과 같다. 다른 배포판은 승인된 저장소나 공식 바이너리를 사용한다. [Restic 설치](https://restic.readthedocs.io/en/stable/020_installation.html)

```bash title="운영 서버 — 도구 설치"
sudo apt-get update
sudo apt-get install -y restic rsync jq
restic version
```

백업 서버에 sudo 권한이 없는 전용 계정을 만든다. 새 계정·새 저장 경로를 만드는 명령이며 기존 사용자를 덮어쓰지 않는다.

```bash title="다른 물리서버 — 저장 공간 준비"
sudo useradd -m -s /bin/bash backup
sudo install -d -o backup -g backup -m 0700 /srv/backup/release-services
```

운영 서버에서 **백업 전용 키**를 만들고 공개키만 백업 서버에 등록한다. 아래 키 경로가 없는지 먼저 확인한다. SSH 호스트 키는 백업 서버 콘솔의 지문과 대조해 등록한다.

```bash title="운영 서버 — 전송 전용 키"
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_backup -N ''
ssh-copy-id -i /root/.ssh/id_ed25519_backup.pub backup@backup.example.com
```

root의 SSH 설정에 다음 Host를 추가한다. 백업 계정의 서버 측 공개키에는 가능한 경우 `restrict`를 적용하고 운영 서버에서만 접속되게 제한한다.

```sshconfig title="/root/.ssh/config — 백업 서버 별칭"
Host backup-store
    HostName backup.example.com
    User backup
    IdentityFile /root/.ssh/id_ed25519_backup
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    BatchMode yes
```

암호화 비밀번호는 root 전용 파일에 생성한다. 기존 파일이 있다면 이 명령으로 덮어쓰지 않는다. **비밀번호와 SSH 복구 수단은 운영 서버 밖의 별도 보안 보관소에도 보관**한다. 암호화한 백업 안에만 보관하면 서버 유실 시 백업을 열 수 없다.

```bash title="운영 서버 — 신규 백업용 암호화 비밀번호 파일"
sudo install -d -m 0700 /etc/release-backup
sudo bash -c 'set -o noclobber; umask 077; openssl rand -base64 48 > /etc/release-backup/restic-password'
```

</div>

<p class="subsection-title"><strong>4-2. 설정은 backup.env 한 곳에 둔다</strong></p>

<div class="section-body" markdown="1">

기존 릴리스 설정과 백업 설정은 용도가 다르므로 파일을 분리한다. 아래 파일은 Bash가 읽는 설정이며, 배열 문법 때문에 systemd의 `EnvironmentFile`에 직접 지정하지 않는다. 소유자는 root, 권한은 `0600`으로 둔다.

```bash title="/etc/gitea-runner-env/backup.env"
BACKUP_HOST=release-services
STAGING_DIR=/data/release-service-backup/staging

export RESTIC_REPOSITORY=sftp:backup-store:/srv/backup/release-services
export RESTIC_PASSWORD_FILE=/etc/release-backup/restic-password

GITEA_DATA_DIR=/data/gitea/gitea-data
NEXUS_DATA_DIR=/data/nexus/nexus-data
BUNDLE_BUILDER_DIR=/opt/gitea/bundle-builder
RUNNER_HOME=/var/lib/gitea-runner
TOFU_ROOT=/var/lib/gitea-runner/opentofu
SERVICE_IMAGES_DIR=/opt/gitea/service-images

# services.env에서 사용하는 실제 DB 사용자·DB명과 맞춘다.
GITEA_DB_USER=root
GITEA_DB_NAME=gitea
GITEA_HEALTH_URL=https://127.0.0.1:30000/api/healthz
NEXUS_HEALTH_URL=https://127.0.0.1:55555/service/rest/v1/status

# tar -C / 기준의 상대 경로. 실제 존재하는 운영 경로로 맞춘다.
CONFIG_PATHS=(
  root/compose
  data/gitea/certs
  etc/gitea-runner
  etc/gitea-runner-env
  etc/systemd/system/gitea-runner.service
  etc/systemd/system/haproxy.service.d
  etc/haproxy
  etc/sudoers.d/contrabass-engine-runner
  usr/local/sbin/build-private-release
  usr/local/sbin/update-release-alias
)
```

`root/compose`에는 Compose 파일과 실제 비밀 파일을 포함한다. `.env`가 다른 파일의 심볼릭 링크라면 **링크 대상도 백업 목록에 있어야 한다.** 인증서가 별도 경로에 있거나 service drop-in을 추가했다면 `CONFIG_PATHS`에 실제 경로를 추가한다. 기존 공통 서비스 설정을 읽어 주소·DB 값을 가져오도록 맞춰도 된다.

첫 적용 전에는 기존 Compose의 DB 사용자·데이터 볼륨과 위 설정을 대조한다. root가 아닌 사용자가 쓸 수 있는 설정 파일을 root 스크립트에서 `source`하지 않는다.

```bash title="운영 서버 — staging 초기화와 원격 저장소 생성"
sudo install -d -m 0700 /data/release-service-backup/staging
sudo touch /data/release-service-backup/staging/.release-backup-staging
sudo chmod 0600 /etc/gitea-runner-env/backup.env

sudo bash -c 'source /etc/gitea-runner-env/backup.env; restic init'
```

`restic init`은 최초 한 번만 실행한다. 연결 실패를 새 저장소로 초기화해 해결하려 하지 않는다. [Restic 자동 인증 설정](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)

</div>

<p class="subsection-title"><strong>4-3. 복구에 필요한 서비스 이미지도 준비</strong></p>

<div class="section-body" markdown="1">

장애 당일 Registry 접근이 안 될 수도 있다. 현재 Compose가 실제 사용하는 Gitea·PostgreSQL·Nexus 이미지를 별도 보관한다. 아래 명령은 실행 중인 세 컨테이너에서 이미지 참조를 읽는다. 버전을 추측해 다른 이미지를 새로 받지 않도록, 먼저 각 참조가 실제 실행 이미지와 일치하는지 확인한다.

```bash title="운영 서버 — 최초 구성과 서비스 업그레이드 때 실행"
sudo install -d -m 0700 /opt/gitea/service-images
sudo nerdctl save -o /opt/gitea/service-images/bootstrap-images.tar \
  "$(sudo nerdctl inspect gitea | jq -r '.[0].Config.Image')" \
  "$(sudo nerdctl inspect gitea-db | jq -r '.[0].Config.Image')" \
  "$(sudo nerdctl inspect nexus | jq -r '.[0].Config.Image')"
```

Runner 바이너리와 해당 버전 정보도 `SERVICE_IMAGES_DIR`에 보관한다. containerd·nerdctl을 새 OS에 설치할 바이너리, 서비스 파일과 설치 순서도 함께 준비한다. 애플리케이션 데이터 백업이 빈 OS의 런타임 설치까지 대신하지는 않는다.

</div>

---

## 5. 백업 실행과 자동 일정

백업 스크립트는 [backup-release-services.sh 다운로드](../assets/gitea-lightweight-9/backup-release-services.sh)로 제공한다. 내용을 확인하고 `/usr/local/sbin/backup-release-services`에 root 소유 `0750`으로 설치한다. CI 계정에 이 스크립트의 sudo 실행 권한을 줄 필요는 없다.

| 단계 | 스크립트 동작 |
| --- | --- |
| 사전 검사 | 명령·볼륨·staging 표식·컨테이너 가동·동시 백업 여부 확인 |
| 1 | 가동 중 Gitea·Nexus 파일 사전 복사. Nexus DB는 이때 제외 |
| 2 | Runner 정상 종료 대기 후 Gitea·Nexus 정지. PostgreSQL 유지 |
| 3 | 최종 rsync, PostgreSQL dump, 빌더·설정·Runner 키·OpenTofu 복사 |
| 4 | Gitea·Nexus 재개, healthcheck 확인 후 Runner 재개 |
| 5 | 고정된 staging을 Restic으로 암호화해 다른 물리서버에 전송 |

`rsync --delete`는 **staging 하위 복사본의 사라진 파일을 맞추는 데만** 사용한다. 운영 데이터나 원격 Restic 저장소를 rsync 대상으로 사용하지 않는다. 이중 실행은 `flock`으로 막는다.

!!! warning "처음에는 수동 유지보수 창에서 실행한다"
    실행 중인 Actions와 Nexus 정리 작업이 없는지 확인한다. Runner는 SIGTERM 후 실행 중 작업을 기다릴 수 있도록 `shutdown_timeout`을 작업 최장 시간보다 길게, systemd `TimeoutStopSec`는 그보다 더 길게 둔다. 백업을 서두르려고 Runner나 Nexus를 강제 kill하지 않는다. 설정·버전별 정상 종료와 재기동을 먼저 확인한 뒤 일정을 활성화한다.

중간 복사에 실패하면 원격 새 snapshot을 만들지 않고 서비스 재개를 시도한다. 재기동·healthcheck에 실패하면 Runner를 멈춘 채 오류로 종료한다. 원격 전송에 실패해도 앞 단계에서 재개한 서비스는 계속 동작하지만, **해당 날짜의 원격 백업은 실패**다. staging은 재시도·조사용으로 남는다. 로그에서 첫 오류를 확인한다.

<details class="analysis-toggle" markdown="1">
<summary>systemd service·timer와 실행 확인</summary>

다운로드한 파일의 이름을 바꿔 설치한 디렉터리에서 실행한다. 설치 경로가 기존 파일과 겹치면 먼저 diff를 확인한다.

```bash title="운영 서버 — 백업 명령 설치와 첫 실행"
sudo install -o root -g root -m 0750 backup-release-services.sh \
  /usr/local/sbin/backup-release-services
sudo /usr/local/sbin/backup-release-services
```

```ini title="/etc/systemd/system/release-services-backup.service"
[Unit]
Description=Consistent backup of release services
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=/usr/local/sbin/backup-release-services
TimeoutStartSec=12h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

매일 01:00은 서버의 현지 시간 기준이다. 먼저 `timedatectl`로 시간대를 확인한다. `Persistent=false`로 두어 서버를 업무 시간에 켰다는 이유만으로 놓친 중단 백업이 즉시 실행되지 않게 한다. 놓친 백업은 다음 유지보수 창에서 수동 실행한다.

```ini title="/etc/systemd/system/release-services-backup.timer"
[Unit]
Description=Daily release-services backup window

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=false
Unit=release-services-backup.service

[Install]
WantedBy=timers.target
```

```bash title="운영 서버 — 일정 활성화와 로그 확인"
timedatectl
sudo systemctl daemon-reload
sudo systemctl enable --now release-services-backup.timer
systemctl list-timers release-services-backup.timer
journalctl -u release-services-backup.service --since today --no-pager
sudo bash -c 'source /etc/gitea-runner-env/backup.env; restic snapshots --host "$BACKUP_HOST" --tag release-services'
```

백업 서버가 가득 찼거나 꺼져 있으면 snapshot이 만들어지지 않는다. `inactive`만 보고 성공으로 판단하지 말고 service 종료 코드·로그와 원격 snapshot 시각을 함께 본다. 실패 통지는 기존 모니터링의 systemd 실패 감지에 연결한다.

</details>

---

## 6. 보관 만료와 백업 검사는 별도 실행

보관 규칙 삭제와 백업 데이터의 실제 공간 반환도 분리한다. `forget`은 보관할 snapshot을 고르고, `prune`은 더 이상 참조되지 않는 저장 조각을 회수한다. **새 원격 백업이 성공한 뒤**에 보관 정리를 수행한다. [Restic 보관 정책](https://restic.readthedocs.io/en/stable/060_forget.html)

다음은 운영 서버 root 셸에서 실행한다. 처음에는 `--dry-run` 결과를 확인하고, 대상이 맞을 때만 실제 `forget`을 수행한다. 아래 정리 정책은 다른 호스트·태그의 백업에는 적용하지 않는다.

```bash title="성공한 백업 이후 — 보관 정책 확인과 적용"
source /etc/gitea-runner-env/backup.env
flock -n /run/lock/release-services-backup.lock \
  restic forget --host "${BACKUP_HOST}" --tag release-services \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --dry-run

# 위 목록과 최근 백업 성공을 확인한 뒤 실행
flock -n /run/lock/release-services-backup.lock \
  restic forget --host "${BACKUP_HOST}" --tag release-services \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 3
```

삭제 목록을 확인한 뒤에는 앞 절의 `release-services-backup.service` **[Service] 안에 아래 한 줄을 추가**해 성공한 일간 백업 뒤 보관 정리를 자동화할 수 있다. `ExecStart`가 실패하면 `ExecStartPost`는 실행되지 않는다. 수정 뒤 `systemctl daemon-reload`를 수행한다.

```ini title="일간 백업 성공 후 보관 정책 적용 — [Service]에 추가"
ExecStartPost=/bin/bash -c 'set -euo pipefail; source /etc/gitea-runner-env/backup.env; exec /usr/bin/flock -n /run/lock/release-services-backup.lock /usr/bin/restic forget --host "$${BACKUP_HOST}" --tag release-services --keep-daily 7 --keep-weekly 4 --keep-monthly 3'
```

여기서 `$$`는 systemd가 먼저 변수를 해석하지 않고 Bash에 `$`를 전달하기 위한 표기다. `/usr/bin/restic`과 `/usr/bin/flock`은 설치한 실제 경로를 확인한다. 구조 검사와 prune은 보관 목록 삭제와 달리 더 큰 I/O가 발생하므로 별도 유지보수 작업으로 남긴다. [systemd.service 명령 실행 규칙](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#Command%20lines)

주 1회 백업 완료 후 `prune`과 구조 검사를 수행한다. 모든 일정은 같은 lock을 사용하고, 새 백업이 돌고 있다면 건너뛰어 다음 유지보수 창에서 수행한다. 저장소 공간이 부족해 새 백업을 못 만드는 상황은 미리 용량 경보로 막는다.

```bash title="주간 유지보수 — 운영 서버 root 셸"
source /etc/gitea-runner-env/backup.env
flock -n /run/lock/release-services-backup.lock restic prune
flock -n /run/lock/release-services-backup.lock restic check
```

월 1회에는 `restic check --read-data-subset=5%`로 일부 데이터도 읽어 본다. 기본 `check`는 모든 본문 데이터를 읽는 검사가 아니다. 분기 복구 연습 때는 전체 검사나 순환 부분 검사를 포함한다. [Restic 데이터 검사](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#checking-integrity-and-consistency)

!!! note "최종 Bundle 3개와 백업 보관 기간은 다르다"
    Nexus에서 오래된 Bundle을 삭제해도 이전 백업 snapshot에는 남아 있을 수 있다. 복구용 과거 파일이므로 중복 정책 오류는 아니다. 다만 그 파일도 백업 보관 만료와 prune 이후에는 복구할 수 없다. 고객 계약상 장기 보관이 필요하면 별도 아카이브 기준을 둔다.

백업 저장소를 쓸 수 있는 계정이 탈취되면 백업 삭제 위험도 있다. 전용 계정·암호화만으로 불변 백업이 되는 것은 아니다. 백업 서버의 별도 파일시스템 snapshot이나 정기적인 분리 보관본을 추가하고, 그 관리 권한은 운영 서버에 주지 않는 편이 좋다.

---

## 7. 장애 복구는 같은 버전에서, Runner는 마지막에

복구는 **기존 운영 데이터를 덮어쓰지 않는 빈 대체 서버**에서 시작한다. DNS·서비스 주소를 인계하기 전에는 운영 서버와 격리한다. 복구 작업과 Gitea·Nexus 업그레이드를 한 번에 하지 않는다.

<p class="subsection-title"><strong>7-1. 백업을 빈 디렉터리로 복원</strong></p>

<div class="section-body" markdown="1">

새 서버에 Restic·SSH 복구 키·백업 암호화 비밀번호를 준비한다. `backup.env`의 원격 접속 설정을 복구하고 snapshot ID를 선택한다. 다음 명령은 파일을 작업 디렉터리로 복구할 뿐 애플리케이션을 시작하지 않는다.

```bash title="대체 서버 — 특정 snapshot 선택 후 복원"
source /etc/gitea-runner-env/backup.env
restic snapshots --host "${BACKUP_HOST}" --tag release-services
read -r -p 'Restore snapshot ID: ' snapshot_id
test -n "${snapshot_id}"
install -d -m 0700 /data/restore-review
restic restore "${snapshot_id}" --target /data/restore-review
```

기본 복원은 원래의 절대 경로 구조를 target 아래에 만든다. 예시에서는 복구 파일이 `/data/restore-review/data/release-service-backup/staging/` 아래에 생긴다. 실제 snapshot의 경로는 `restic ls`로 확인한다. [Restic restore](https://restic.readthedocs.io/en/stable/050_restore.html)

복구한 `configuration.tar`를 먼저 **검토용 디렉터리**에 푼다. app.ini·서비스 비밀번호·공통 설정·Compose·인증서·HAProxy map과 포트를 대조한 뒤 필요한 파일을 원래 경로에 복원한다. `tar -C /`로 기존 운영 서버에 바로 덮어쓰지 않는다.

```bash title="대체 서버 — 복구 파일 검토"
recovered=/data/restore-review/data/release-service-backup/staging
tar -tf "${recovered}/configuration.tar"
install -d -m 0700 /data/restore-config-review
tar --acls --xattrs --numeric-owner -xpf "${recovered}/configuration.tar" \
  -C /data/restore-config-review
```

</div>

<p class="subsection-title"><strong>7-2. Gitea와 PostgreSQL 복구</strong></p>

<div class="section-body" markdown="1">

1. 동일한 containerd·nerdctl, 서비스 이미지와 Compose를 준비한다.
2. Gitea 데이터·인증서·app.ini·암호화 키를 복원한다.
3. **빈 PostgreSQL 데이터 경로**를 지정하고 DB 서비스만 시작한다.
4. 백업 당시와 같은 DB 사용자·DB명을 준비하고 dump를 복원한다.
5. DB 복원이 성공한 뒤 Gitea를 시작한다.

빈 서버에서 기존 Compose 설정을 복원한 예시다. `gitea-data`와 `nexus-data`는 서로 같은 snapshot에서 가져온다. `rsync -aHAX --numeric-ids`로 원래 소유권·권한을 보존한다. PostgreSQL 데이터 디렉터리를 실행 중 복사한 파일로 대신하지 않는다.

```bash title="대체 서버 — Gitea 데이터와 DB 복원"
source /etc/gitea-runner-env/backup.env
nerdctl load -i "${recovered}/service-images/bootstrap-images.tar"

install -d -m 0755 "${GITEA_DATA_DIR}"
rsync -aHAX --numeric-ids "${recovered}/gitea-data/" "${GITEA_DATA_DIR}/"

# Compose·서비스 설정·비밀 파일은 앞 단계에서 원래 경로에 복원한 상태
cd /root/compose
nerdctl compose -f gitea-compose.yaml up -d db
nerdctl exec gitea-db pg_isready -U "${GITEA_DB_USER}" -d "${GITEA_DB_NAME}"
# pg_isready가 연결 가능 상태일 때 진행. 빈 DB에만 복원한다.
nerdctl exec -i gitea-db pg_restore --exit-on-error \
  --no-owner --no-acl -U "${GITEA_DB_USER}" -d "${GITEA_DB_NAME}" \
  < "${recovered}/gitea.dump"
nerdctl compose -f gitea-compose.yaml up -d gitea
```

위 dump는 단일 Gitea DB를 복구하는 방식이다. DB 소유자를 같은 계정으로 다시 만들고 복원하므로 `--no-owner --no-acl`을 사용한다. 여러 DB role·확장·별도 권한을 사용한 환경은 role과 권한도 별도 백업·복원해야 한다.

데이터 소유권을 임의로 전부 root로 바꾸지 않는다. Gitea의 UID/GID와 app.ini의 암호화 키가 달라지면 권한·Secret 사용 문제가 생길 수 있다. Git 저장소 경로가 바뀌었다면 공식 복구 문서의 hook 재생성 절차도 확인한다. [Gitea restore](https://docs.gitea.com/1.25/administration/backup-and-restore/#restore-command-restore)

</div>

<p class="subsection-title"><strong>7-3. Nexus와 HAProxy 복구</strong></p>

<div class="section-body" markdown="1">

Nexus는 **처음 기동하기 전에** DB·Blob·설정·node identity를 함께 복원한다. 빈 Nexus를 먼저 초기화한 뒤 그 위에 옛 DB 일부만 섞지 않는다.

```bash title="대체 서버 — 동일 snapshot의 Nexus 전체 복원"
install -d -m 0755 "${NEXUS_DATA_DIR}"
rsync -aHAX --numeric-ids "${recovered}/nexus-data/" "${NEXUS_DATA_DIR}/"
cd /root/compose
nerdctl compose -f nexus-compose.yaml up -d nexus
```

Nexus가 정상 기동하면 Repository·Blob Store·사용자·역할과 실제 파일 다운로드를 확인한다. 별도 경로의 Blob Store를 사용한 환경은 그 경로도 복원해야 한다. 이 글의 예시는 모든 Blob이 nexus-data 안에 있는 단일 파일 Blob Store를 전제로 한다.

HAProxy 설정과 `bundle-channels.map`도 복원하고 설정 검사 후 기동한다. 파일의 map과 Runtime API의 map은 구분된다. 복구 기동 시에는 복원한 파일이 기준이다. 채널이 가리키는 실제 TAR가 같은 Nexus 복구본에 있는지 확인한다.

```bash title="대체 서버 — HAProxy 설정 검사와 기동"
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl start haproxy
```

설정에서 환경변수를 참조하면 기존 systemd drop-in과 공통 환경 파일도 먼저 복원하고, 검사 명령에도 그 환경을 전달한다.

</div>

<p class="subsection-title"><strong>7-4. Runner는 데이터 확인 뒤 마지막으로 기동</strong></p>

<div class="section-body" markdown="1">

Runner 바이너리·사용자 UID/GID·설정·등록 파일·SSH 키, 빌더·wrapper·sudoers를 복원한다. `.runner` 파일을 복구할 수 없으면 새 등록 Token으로 다시 등록한다. 운영 인스턴스와 복구 인스턴스에서 같은 Runner 등록을 동시에 사용하지 않는다.

OpenTofu State가 가리키는 VM이 실제로 남아 있는지도 확인한다. **복구했다는 이유로 바로 apply나 destroy를 실행하지 않는다.** 오래된 State와 현재 VMware·OpenStack 상태가 다를 수 있다.

아래 항목을 통과한 뒤 Runner를 시작하고 계획된 수동 실행부터 확인한다.

| 확인 대상 | 통과 기준 |
| --- | --- |
| Gitea | 로그인, 저장소·Tag 조회, clone 가능 |
| 운영 기록 | 기존 PR 승인·보호 규칙·Release 설명 조회 가능 |
| Secret | 시험용 최소 작업에서 읽기·인증 가능, 값은 출력하지 않음 |
| Nexus | Repository 목록, 지정 파일 다운로드·SHA256 일치 |
| 채널 | current·계열 URL의 302가 존재하는 실제 TAR로 연결 |
| 권한 | 사업수행팀은 최종 TAR 읽기 가능, staging 쓰기·삭제 불가 |
| Runner | 등록 연결·label 일치, 기존 작업 자동 재개 여부 확인 |

```bash title="대체 서버 — 마지막 Runner 기동"
systemctl daemon-reload
systemctl start gitea-runner
systemctl status gitea-runner --no-pager
```

</div>

---

## 8. 백업의 완료 기준은 복구 가능한가다

명령의 종료 코드가 0이고 원격 snapshot이 생긴 것은 **백업 생성 확인**이다. 빈 서버에서 Gitea·Nexus·채널·Runner를 복원한 것은 **복구 확인**이다. 둘은 같은 결과가 아니다.

분기 복구 연습에서는 복구 시점·소요 시간·빠진 설정·실패 원인을 기록한다. 운영 DNS와 연결하지 않은 대체 서버에서 수행하고, 끝나면 실제 서비스로 오인해 접근하지 못하도록 정리한다. 백업 실패를 며칠 방치하지 않도록 담당자와 확인 시간을 정하는 것까지 운영 절차다.

1편의 문제는 코드를 받기 위해 과거 이미지까지 내려받아야 한다는 것이었다. 지금은 Git이 코드와 릴리스 기준을, Nexus가 설치 재료와 배포물을, Runner가 패키징·시험·게시를 맡는다. 여기에 **승인 규칙·보관 정책·복구 절차**가 붙어야 그 구조를 계속 운영할 수 있다.

[← 8편: Nexus와 배포 이미지 관리](2026-10-22-gitea-lightweight-8.md) · [1편: 왜 경량화를 시작했나](2026-10-15-gitea-lightweight-1.md)
