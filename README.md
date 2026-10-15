# 셈셈 점프

자연수 사칙연산 문제를 풀고 정답 계단으로 폴짝 뛰어 우주까지 올라가는 레트로 픽셀 게임.
만든이 빵쌤 (ppang_sem).

## 폴더

| 경로 | 내용 |
|---|---|
| `src/game.html` | 게임 원본 (HTML, CSS, JS). 고칠 때는 이 파일만 고쳐요 |
| `assets/` | 스프라이트, 효과음, 배경음악, 글꼴과 각 라이선스 |
| `assets/music-source/` | 배경음악 원본 ogg (m4a로 다시 변환할 때 사용) |
| `build.py` | 원본과 에셋을 하나로 합쳐 `dist/semsem-jump.html` 생성 |
| `tests/check_levels.py` | 19개 레벨의 문제를 대량 생성해 정답·음수·받아올림 조건 검사 |

## 빌드와 검사

```bash
python3 build.py
```

```bash
python3 tests/check_levels.py
```

`dist/semsem-jump.html` 한 파일만 있으면 인터넷 없이도 실행돼요.

## 배경음악 다시 변환

```bash
afconvert -f m4af -d aac -b 80000 assets/music-source/flowerbed_fields.ogg assets/music/mus_main.m4a
```

곡을 바꾸면 `src/game.html`의 `TRACKS`에 새 곡의 프레임 수(`afinfo`의 valid frames)를 넣어야 반복 지점이 정확해요.

## 라이선스

- 그림·효과음: Kenney (CC0) — `assets/LICENSE-kenney_*.txt`
- 배경음악: Zane Little Music, OpenGameArt (CC0)
- 글꼴: 갈무리 Galmuri11 © Lee Minseo (SIL OFL 1.1) — `assets/font/LICENSE.txt`
