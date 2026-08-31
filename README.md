# paper-reader_web-ver

논문 읽기 편한 프로그램입니다.

PDF 논문을 읽으면서 **드래그 번역**과 **논문 질문 채팅**을 쓸 수 있는 로컬 웹 앱.
모든 AI 호출은 이 PC에 설치된 Claude Code CLI(`claude.exe`)를 통해 처리된다. 별도 API 키 불필요.

## 필요한 것

- Windows + Windows PowerShell 5.1 (기본 탑재)
- [Claude Code](https://claude.com/claude-code) 설치 및 로그인 — 서버가 `claude.exe`를 자동으로 찾는다
- [Git for Windows](https://git-scm.com/download/win) — PDF 텍스트 추출에 포함된 `pdftotext`를 쓴다

## 실행

`start.bat` 더블클릭 → 브라우저가 `http://127.0.0.1:8765/`로 자동으로 열린다.
서버 창(PowerShell)은 읽는 동안 켜 둔다. 닫으면 서버가 종료된다.

처음 실행하면 불러온 논문이 없다. 화면의 **PDF 가져오기**(또는 상단 `논문 ▾` 메뉴)로
읽을 PDF를 선택하면 텍스트 추출까지 끝난 뒤 바로 읽을 수 있다.
가져온 논문과 대화 기록은 `data\`에 로컬로만 저장되며 저장소에 올라가지 않는다.

## 기능

| 기능 | 사용법 |
|---|---|
| 드래그 번역 | 본문 텍스트를 드래그 → 팝업에서 `번역` 클릭. 모델은 **Sonnet·보통 생각깊이로 고정**(변경 불가), 같은 문장은 캐시되어 즉시 표시 |
| 질문에 첨부 | 드래그 → `질문에 첨부` → 선택 부분이 인용된 채로 채팅 질문 |
| 논문 채팅 | 오른쪽 사이드바. 논문 전문이 매 질문에 함께 전달되며, 답변의 `[p.N]`을 누르면 해당 페이지로 이동 |
| 모델·생각 깊이 선택 | 채팅 입력창 **아래** 드롭다운 2개. 모델: Sonnet/Opus/Haiku/Fable, 생각 깊이: 가볍게/보통/깊게/아주 깊게/최대. 선택값은 브라우저에 저장되어 다음 방문에도 유지 |
| 세션 | 질문을 보내면 자동으로 저장된다. 사이드바 `세션 ▾`에서 이전 세션 목록을 열고, 클릭하면 그 대화를 이어간다(다른 논문의 세션이면 그 논문으로 자동 전환). `×`로 삭제. 서버를 껐다 켜도 유지된다 |
| 새 대화 | `새 대화` 버튼 — 새 세션 시작(이전 세션은 목록에 남음) |
| PDF 가져오기 | 상단 `논문 ▾` → `PDF 가져오기…` → 파일 선택. 텍스트 추출까지 자동으로 끝나면 그 논문으로 전환된다. 가져온 논문들은 같은 메뉴에서 골라 다시 열 수 있다 |

## 구조

```
paper-reader/
  server.ps1       로컬 HTTP 서버 (PowerShell HttpListener, ASCII 전용)
  prompts.json     번역·채팅 프롬프트 (한국어, UTF-8)
  start.bat        실행 진입점
  web/index.html   리더 UI (pdf.js 렌더링 + 번역 팝업 + 채팅)
  vendor/          pdf.js 4.10.38 (로컬 사본)
  data/
    papers/<id>/   논문 라이브러리: paper.pdf + paper.txt(페이지 마커) + meta.json(제목)
    sessions/      세션별 대화 기록 (<key>.json)
    active.json    현재 열려 있는 논문 id
```

- 번역: `claude -p --safe-mode --model sonnet --tools ""` 단발 호출, stdin으로 프롬프트 전달.
- 채팅: CLI `--resume`이 print 모드에서 맥락을 잇지 못해, 서버가 대화 이력을 보관하고
  매 턴 논문 전문 + 이력(최근 16문답)을 함께 보낸다. 이력 전체는 디스크에 저장된다.
- PDF 가져오기: 업로드 → Git의 pdftotext로 텍스트 추출 → `===== [p.N] =====` 페이지 마커 부여
  → `data\papers\p<타임스탬프>\`에 저장 후 활성화. pdftotext가 없으면 메뉴에 비활성으로 표시된다.
