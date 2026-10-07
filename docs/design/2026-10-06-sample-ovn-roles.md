---
title: "샘플: OVN에서 NB와 SB가 나뉘는 이유"
summary: 문서에서 자주 만나는 Northbound와 Southbound 역할을 샘플로 정리한다. 특정 클러스터의 구축 기록이 아니다.
date: 2026-10-06
category: 개념·설계
tags:
  - Network
  - OpenStack
sample: true
spotlight: true
spotlight_note: 화면 확인용으로 둔 개념 글이다. 이어서 쓸 실습 기록이 아직 없다.
---

이 글은 목차, 표, 코드 블록, 주의 상자가 긴 글에서 어떻게 보이는지 확인하는 샘플이다. 아래 설명은 OVN 문서에서 반복되는 역할 구분이고, 어떤 환경에서 실행해 확인한 절차가 아니다.

## 두 데이터베이스

OVN은 논리 구성과 스위치에 내려갈 상태를 한 통에 넣지 않는다.

- Northbound(NB)는 논리 스위치, 논리 라우터, ACL처럼 사람이 선언하는 구성에 가깝다.
- Southbound(SB)는 그 구성을 하이퍼바이저의 Open vSwitch가 수행할 흐름으로 옮긴 쪽에 가깝다.

한쪽에 적은 내용이 다른 쪽에 그대로 복사된다고 보면 역할이 섞인다. NB를 고친 뒤 SB와 포트 바인딩이 따라왔는지 따로 본다.

## 컨트롤러가 서는 자리

`ovn-northd`는 NB를 읽어 SB를 갱신한다. 각 컴퓨트 노드의 `ovn-controller`는 SB와 로컬 vSwitch를 맞춘다. 중앙에서 논리 구성을 고쳤는데 특정 노드만 반영되지 않으면, 그 노드의 컨트롤러와 섀시 등록을 먼저 의심할 수 있다. 이것도 샘플에서 쓰는 질문 순서일 뿐, 이번 글의 재현 결과는 아니다.

## 역할 표

| 구성 요소 | 주로 보는 것 | 샘플에서 하지 않은 것 |
| --- | --- | --- |
| NB | 논리 스위치, 라우터, ACL | 운영 클러스터 변경 |
| northd | NB를 SB로 옮기는 일 | 프로세스 재시작 |
| SB | 포트 바인딩, 섀시 | 실측 지연 |
| ovn-controller | 로컬 플로우 반영 | 패킷 캡처 |

표가 좁은 화면보다 넓어지면 표 안에서만 가로로 움직이고, 페이지 전체가 밀리면 안 된다.

## 예시로만 보는 명령

아래는 공식 문서와 안내서에 자주 나오는 조회 형태다. 이 저장소를 만들 때 이 명령을 실행하지 않았다.

```bash
ovn-nbctl show
ovn-sbctl show
ovn-sbctl list Chassis
echo "this is a deliberately long sample command line that should scroll inside the code block rather than stretching the whole page layout past the viewport"
```

!!! warning "샘플"
    위 명령은 모양을 보여 주기 위한 예시다. 접속 중인 클러스터에서 그대로 실행하라는 절차가 아니다.

## 그림으로 보는 순서

논리 구성을 적고, 변환이 따라오고, 노드가 반영하는 순서를 샘플 그림으로만 두었다.

![증상에서 확인으로 이어지는 샘플 흐름](../assets/sample-flow.svg)

## 이 글의 한계

- OpenStack Neutron ML2/OVN 드라이버 설정은 다루지 않는다.
- 버전별 스키마 차이는 적지 않았다.
- 성능 수치, 장애 시간, 노드 수는 없다. 확인한 값이 없기 때문이다.

다음에 실습을 하면 환경, 버전, 실행한 명령, 나온 출력을 별도 글에 둔다. 이 샘플 문단을 결과처럼 고치지 않는다.
