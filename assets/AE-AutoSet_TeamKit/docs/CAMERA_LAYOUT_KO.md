# Camera Plan 내부 명세

카메라 판독·보류·보간 정책은 스킬의 [camera.md](../../../references/camera.md)에만 둔다. 이 문서는 구현·형식 확인용이며 별도 실행 공정이 아니다.

## 입력과 출력

- [계획 스키마](../schemas/camera.plan.schema.json)
- 필드: version, cut_number, fps, total_frames, stage_name, camera_layer, layout_source, image_size, keys, evidence.
- keys의 항목: {frame,label,rect,slow}; rect는 LO 원본 픽셀의 [left,top,right,bottom].
- stage_name과 camera_layer는 활성 작품 프로필의 값이다.
- 적용 결과는 camera.applied.json에 기록한다.

## 좌표와 키 시간

타임시트의 1기반 프레임은 AE 시간 (frame - 1) / fps로 변환한다. 셀 캔버스 보정 후 실제 LO 레이어의 Position·Scale·Anchor Point를 반영해 Stage 좌표 및 기존 2D camera의 Position·X/Y Scale 값을 계산한다.

기본 Session은 Prepare 전에 계획을 받고 셀·LO 다음에 카메라를 적용한다. APPLY_CAMERA_LAYOUT.jsx는 명시적으로 승인된 단독 후처리용이며 기본 Session과 중복 사용하지 않는다.
