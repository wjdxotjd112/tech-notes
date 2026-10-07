# attrs linecache 백포트 코드 비교

실행용 패키지가 아닌 `python3-attrs-20.3.0-7.el9.noarch`의 소스 비교 자료.

- [원본 코드](https://github.com/wjdxotjd112/tech-notes/blob/4ebd34d/examples/attrs-linecache/attr/_make.py)
- [수정 코드와 실제 변경 줄](https://github.com/wjdxotjd112/tech-notes/commit/93fe7d8ee88b13328e773f69ed50f991866f0542)
- [원인 분석·검증·운영 주의사항](https://wjdxotjd112.github.io/tech-notes/troubleshooting/2026-10-07-openstack-attrs-linecache/)

다른 버전의 파일에 그대로 덮어쓰지 않고 대상 원본과 diff 확인 필요. attrs의 MIT 라이선스는 [LICENSE](LICENSE) 참고.
