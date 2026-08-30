# Todo Sticker

맥 데스크톱에 포스트잇처럼 떠 있는 초경량 투두 위젯.

- 상단바 체크리스트 아이콘: 클릭 = 위젯 보이기/숨기기, 우클릭 = 메뉴(종료)
- 체크박스는 왼쪽, 행을 드래그하면 순서 변경, 마우스 올리면 ✕로 삭제
- 아래 입력칸에 쓰고 Enter → 목록 아래로 추가
- 창은 드래그로 이동, 모서리로 크기 조절, 위치·목록 자동 저장
- 데이터: `~/Library/Application Support/TodoSticker/todos.json`

## 빌드 & 실행

```bash
./build.sh
open "Todo Sticker.app"
```

## 로그인 시 자동 시작

시스템 설정 → 일반 → 로그인 항목 → `+` → Todo Sticker.app 추가
