---
title: "샘플: OVN에서 NB와 SB가 나뉘는 이유"
summary: 문서에서 자주 만나는 Northbound와 Southbound 역할 샘플. 특정 클러스터의 구축 기록은 아님
date: 2026-10-06
category: 구축설계
tags:
  - Network
  - OpenStack
sample: true
spotlight: true
spotlight_note: 화면 확인용 개념 글. 이어서 쓸 실습 기록은 아직 없음
---

목차, 표, 코드 블록, 주의 상자 확인용 샘플. 아래는 OVN 문서의 역할 구분이며, 특정 환경에서 실행해 확인한 절차는 아님.

## 두 데이터베이스

OVN은 논리 구성과 스위치에 내려갈 상태를 한 통에 두지 않음.

- Northbound(NB): 논리 스위치, 논리 라우터, ACL처럼 사람이 선언하는 구성
- Southbound(SB): 그 구성을 하이퍼바이저의 Open vSwitch가 수행할 흐름으로 옮긴 쪽

한쪽 내용이 다른 쪽에 그대로 복사된다고 보면 역할이 섞임. NB 수정 후 SB와 포트 바인딩 반영은 따로 확인.

## 컨트롤러가 서는 자리

`ovn-northd`는 NB를 읽어 SB를 갱신. 각 컴퓨트 노드의 `ovn-controller`는 SB와 로컬 vSwitch를 맞춤. 중앙에서 논리 구성을 고쳤는데 특정 노드만 미반영이면, 그 노드의 컨트롤러와 섀시 등록을 먼저 의심 가능. 샘플에서 쓰는 질문 순서일 뿐, 이번 글의 재현 결과는 아님.

## 역할 표

| 구성 요소 | 주로 보는 것 | 샘플에서 하지 않은 것 |
| --- | --- | --- |
| NB | 논리 스위치, 라우터, ACL | 운영 클러스터 변경 |
| northd | NB를 SB로 옮기는 일 | 프로세스 재시작 |
| SB | 포트 바인딩, 섀시 | 실측 지연 |
| ovn-controller | 로컬 플로우 반영 | 패킷 캡처 |

표가 화면보다 넓으면 표 안에서만 가로 이동. 페이지 전체는 밀리지 않음.

## 예시로만 보는 명령

공식 문서와 안내서에 자주 나오는 조회 형태. 이 저장소를 만들 때 아래 명령은 미실행.

```bash
ovn-nbctl show
ovn-sbctl show
ovn-sbctl list Chassis
echo "this is a deliberately long sample command line that should scroll inside the code block rather than stretching the whole page layout past the viewport"
```

!!! warning "실행 주의"
    - 화면 확인용 예시 명령
    - 접속 중인 클러스터에서 실행할 절차는 아님

## 그림으로 보는 순서

논리 구성 기록, 변환, 노드 반영 순서만 샘플로 표시. 실행 결과는 아님.

<figure class="flow">
  <ol>
    <li>논리 구성</li>
    <li>변환</li>
    <li>노드 반영</li>
  </ol>
  <ul>
    <li>Northbound 선언, northd 변환, 노드의 ovn-controller 반영 순서</li>
  </ul>
</figure>

## 이 글의 한계

- OpenStack Neutron ML2/OVN 드라이버 설정은 범위 밖
- 버전별 스키마 차이는 미기록
- 성능 수치, 장애 시간, 노드 수 없음. 확인한 값이 없기 때문

다음 실습 시 환경, 버전, 실행 명령, 출력을 별도 글에 기록. 이 샘플 문단을 결과로 고치지 않음.
