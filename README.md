# DD2 Item Guard

Dragon's Dogma 2용 REFramework Lua 모드입니다. 인벤토리에서 관찰된 아이템을 규칙으로 등록하고, 지정한 수량보다 줄어들면 `ItemManager:getItem`을 이용해 다시 채웁니다.

## 기능

- REFramework `Script Generated UI` 패널 제공
- 인벤토리 UI에서 보인 아이템을 `min` 규칙으로 추가
- `min` / `fixed` 모드 선택
- 현재 플레이어 `CharaID` 기준으로 부족분 복구
- 설정 저장: `reframework/data/dd2_item_guard.json`
- 기본값은 치트 비활성화 상태

## 설치

Fluffy Mod Manager에서 `DD2_Item_Guard_v0.5.0.zip`을 설치하고 활성화합니다.

수동 설치 시 파일 구조는 다음과 같습니다.

```text
reframework/
  autorun/
    dd2_item_guard.lua
  data/
    dd2_item_guard.json
modinfo.ini
```

## 사용

1. REFramework UI를 열고 `Script Generated UI > DD2 Item Guard`를 엽니다.
2. 게임 인벤토리에서 대상 아이템이 보이도록 합니다.
3. `Observed UI items`에서 `Add min`을 누릅니다.
4. `Item guard rules`에서 목표 수량과 `min` 또는 `fixed`를 설정합니다.
5. `Enable enforcement`를 누릅니다.
6. 필요하면 `Save config`로 설정을 저장합니다.

## 주의

오프라인 플레이 전용으로 사용하세요. 세이브 백업을 권장합니다.
