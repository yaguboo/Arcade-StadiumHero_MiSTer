# Stadium Hero — MiSTer FPGA 코어

> [!IMPORTANT]
> **취미로 만든 프로젝트입니다.**
> 개인이 순전히 취미로 만든 코어입니다. 버그 제보는 반갑게 받지만, **대응할 수도 있고 못 할 수도 있습니다.**
> 업데이트나 지원을 약속하지 않습니다.
>
> **이 코드로 이어서 개발하실 때는 꼭 출처를 남겨 주세요.**
> 이 저장소를 바탕으로 수정하거나 다른 코어를 만드실 때 출처(이 저장소 링크)를 밝혀 주시면 정말 감사하겠습니다.
> 라이선스(GPL-3.0)에 따라 원래의 저작권 표시와 이 프로젝트가 감사를 전한 분들의 출처도 함께 유지해 주세요.

Data East 가 1988 년에 내놓은 야구 게임 **Stadium Hero** 의 아케이드 기판
(DE-0303-3 + DE-0304-3)을 FPGA 로 재현한 MiSTer 코어입니다.

기판 구성은 다음과 같습니다.

| | |
|---|---|
| 메인 CPU | Motorola 68000 @ 10 MHz (20 MHz XTAL / 2) |
| 사운드 CPU | 65C02 @ 1.5 MHz (24 MHz XTAL / 16) |
| 사운드 | YM2203 @ 1.5 MHz, YM3812 @ 3 MHz, OKI M6295 @ 1.056 MHz (pin 7 high) |
| 타일맵 | Data East L7B0072 "BAC06" — 16×16 배경 |
| 스프라이트 | Data East L7B0073 "MXC06" |
| 텍스트 | 커스텀 칩 없는 8×8 텍스트 타일맵 |
| 화면 | 384 × 272 @ 6 MHz, 표시 영역 256 × 240, 57.44 Hz |

세 레이어(배경 → 스프라이트 → 텍스트)를 우선순위 혼합 없이 고정 순서로
겹칩니다. 코어 전체가 60 MHz 단일 클럭 도메인에서 클럭 인에이블로 동작하며,
두 개의 크리스털(20 MHz, 24 MHz)에서 나오는 CPU·픽셀·사운드 클럭을 모두
정수 분주로 정확히 만듭니다 (M6295 만 별도 레조네이터라 분수 분주).

## 지원 게임

| MAME set | 공식 명칭 | 상태 |
|---|---|---|
| `stadhero` | Stadium Hero (Japan) | MiSTer 실기에서 플레이 가능 (2026-09-15 1차 완성) |

MAME 의 `stadhero` 드라이버에는 이 세트 하나뿐입니다. *Stadium Hero '96* 은
완전히 다른 기판(`deco_mlc`)이라 이 코어의 대상이 아닙니다.

배포용 `.mra` 는 `Stadium Hero.mra` 이며, **MAME 의 `stadhero.zip` 을 그대로**
읽습니다. 별도로 가공한 ROM 파일은 필요하지 않습니다.

## 설치 — ROM 만 넣으면 됩니다

이 배포본의 `SD/` 폴더는 MiSTer SD 카드의 루트(`/media/fat/`)와 같은 구조입니다.
**`SD/` 안의 내용을 SD 카드 루트에 그대로 복사**하면 됩니다.

```
SD/_Arcade/cores/StadiumHero.rbf                 코어 (빌드된 비트스트림)
SD/_Arcade/_Kaze's Cores/<게임 이름>.mra    게임 목록 (공식 명칭)
SD/games/mame/필요한_ROM.txt               넣어야 할 ROM zip 목록
```

1. `SD/` 의 내용을 SD 카드 루트에 복사합니다. 기존 파일은 덮어써도 됩니다.
2. 직접 마련한 MAME ROM 세트 zip 을 SD 카드의 `/games/mame/` 에 넣습니다.
   어떤 zip 이 필요한지는 `필요한_ROM.txt` 에 게임별로 적혀 있습니다.
   zip 은 MAME 세트 이름 그대로 두고, 압축을 풀지 않습니다.
3. MiSTer 메뉴에서 **Arcade → `_Kaze's Cores`** 로 들어가 게임을 고릅니다.

- `.rbf` 를 직접 실행하지 말고 `.mra` 로 실행하세요. ROM 로드와 DIP·OSD 기본값이
  `.mra` 에 들어 있습니다.
- 폴더 이름이 `_` 로 시작해야 MiSTer 메뉴에 보입니다. 이름을 바꾸지 마세요.


## 빌드 방법

필요한 것: **Intel Quartus Prime Lite Edition 17.0** (MiSTer 코어 표준 버전). 다른 버전에서도
합성은 될 수 있지만 검증한 버전은 17.0 입니다.

```sh
cd projects/dataeast/stadium_hero/targets/mister
quartus_sh --flow compile StadiumHero
```

결과물은 `projects/dataeast/stadium_hero/targets/mister/output_files/StadiumHero.rbf` 입니다. Quartus GUI 로
`StadiumHero.qpf` 를 열고 Compile 을 눌러도 같습니다.

- 디렉터리 구조를 그대로 유지해야 합니다. 프로젝트 파일이 `../../../../../third_party`,
  `../../../../../platforms/mister/sys` 를 상대 경로로 찾습니다.
- `build_id.v` 는 빌드 시작 때 `platforms/mister/sys/build_id.tcl` 이 자동으로 만듭니다.
- Quartus 17.0 의 fitter 가 드물게 내부 오류로 죽으면서도 정상 종료 코드를 남기는 경우가 있습니다.
  `.rbf` 의 생성 시각과 로그 끝부분을 확인하고, 그런 경우 한 번 더 빌드하면 됩니다.

직접 빌드한 `.rbf` 는 `SD/_Arcade/cores/` 의 같은 이름 파일과 바꿔 넣으면 됩니다.

## 디렉터리 구성

원래 저장소의 상대 경로를 그대로 유지했습니다. 빌드에 실제로 쓰이는 파일만 들어 있습니다.

```
LICENSE                              GPL-3.0 전문
README.md                            이 문서
SD/                                  SD 카드 루트에 복사할 설치 파일 (RBF, MRA, ROM 목록)
projects/dataeast/stadium_hero/
  rtl/                               기판 하드웨어 RTL (68000·65C02 버스, 비디오·사운드, 메모리 RTL)
  integration/                       ROM 다운로드 경로 (플랫폼 중립 어댑터)
  targets/mister/                    MiSTer 최상위 (.qpf .qsf .sdc .sv files.qip, PLL)
third_party/                         외부 IP (아래 "감사의 말과 사용한 코드" 참조)
platforms/mister/sys/                MiSTer framework (Template_MiSTer)
```

소스 주석에는 개발 중에 쓴 내부 문서 번호와 측정 기록이 그대로 남아 있습니다. 해당 개발
문서와 측정·분석 도구는 이 배포본에 포함하지 않았습니다. 빌드에는 영향이 없습니다.

## 작업 내역

### 2026-10-08

- **OSD 설정 저장 유지.** 이전에는 `Save settings` 로 저장해도 다음 실행 때 코어가 `.mra` 기본값을 다시 올려 저장값을 덮어썼습니다(MiSTer 는 저장 파일을 ROM 로드 전에 읽고, 코어가 보낸 status 로 128비트 전체를 교체합니다). 이제 저장된 설정이 있으면 기본값을 올리지 않습니다. 실기에서 저장 파일 값이 화면에 반영되는 것을 확인했습니다.

### 일정

| 날짜 | 내용 |
|---|---|
| 2026-09-03 | 프로젝트 시작. 사운드 CPU 동작, 첫 비트스트림 (장치의 약 30 %, 타이밍 충족) |
| 2026-09-03 | 비디오 경로 전체를 MAME 덤프와 대조하는 골든 모델 작성 — 프레임 단위 100 % 일치 |
| 2026-09-04 | 실기 화면이 MAME 와 픽셀 단위로 일치함을 확인. 사운드 믹스 보정 |
| 2026-09-04 | 보드 전체를 Verilator 로 시뮬레이션, 워크 RAM 이 MAME 와 일치 |
| 2026-09-14 | 타격·투구 게임성 문제의 원인 규명과 수정, 버튼 이름 정리 |
| 2026-09-15 | **1차 완성** — 수정된 코어를 실기에서 플레이하여 확인 |
| 2026-10-06 | 배포 `.mra` 가 MAME 의 `stadhero.zip` 을 직접 읽도록 수정 |

### 블록별 구현

- **68000** — fx68k. 프로그램 ROM 은 칩 내부 블록 RAM 에 둡니다 (아래 참고).
- **사운드 보드** — jt65c02 (65C02) + jt03 (YM2203) + jtopl2 (YM3812) +
  jt6295 (M6295). 주소 디코드는 MAME 드라이버를 기준으로 하고, jotego 의
  `jtcop_snd.v` 가 같은 영역을 같은 주소에 디코드한다는 점을 교차 확인에
  썼습니다. 65C02 의 마이크로코드는 jtcores 의 yaml 정의에서 jtframe 생성기로
  만들었습니다.
- **BAC06 타일맵 / MXC06 스프라이트** — 이 기판에 맞춰 새로 작성한 RTL.
  레지스터 의미와 속성 디코드는 MAME 의 `decbac06.cpp` / `decmxc06.cpp` 를
  따르고, jtcores 의 `jtcop` 을 독립적인 두 번째 해석으로 대조했습니다.
  RoboCop 에는 없는 BAC06 VRAM 뱅크 기능과 스프라이트 DMA 가 없는 이 기판의
  구조를 반영했습니다.
- **텍스트 레이어, 팔레트, 래스터 타이밍** — 자체 RTL. 래스터 상수(DEC0 계열)는
  jtcop 에서 확인하고 이 기판의 실측 HSync/VSync 와 독립적으로 맞춰 봤습니다.
- **ROM 중재** — SDRAM 에 둔 그래픽·사운드 ROM 을 여러 클라이언트가 나눠
  읽습니다. 기다릴 수 없는 M6295 를 가장 앞 순위에 둡니다.

### 해결한 주요 문제

- **타자의 머리가 없었다** — 스프라이트의 투명 색(pen 0)이 라인 버퍼에 써져
  뒤의 그림을 지웠습니다. MAME 덤프 기반 골든 모델로 찾았습니다.
- **글자가 반으로 잘리고 깜박였다** — 라인 번호를 라인 중간에 읽고 있었습니다.
  HSync 에서 래치하도록 고쳤습니다.
- **3bpp 레이어의 팔레트 간격**, **타일맵 주소 계산**, **화면 반전 시 1 픽셀
  어긋남**, **싱크 신호의 3 픽셀 지연** — 모두 MAME 와의 픽셀 대조로 찾아 고쳤습니다.
- **라인 버퍼가 플립플롭으로 합성되어 설계의 48 % 를 차지** — 같은 사이클
  읽기·지우기를 분리해 블록 RAM 으로 추론되게 했고, 설계 크기가 절반 가까이
  줄었습니다.
- **YM2203 의 FM 과 SSG 게인이 뒤바뀌어 있었다** — MAME 의 YM 라우팅을 읽고
  FBNeo 로 교차 확인해 바로잡았습니다.
- **"세이프/아웃" 음성이 나오지 않았다** — M6295 가 ROM 중재에서 마지막 순위라
  재생 시작이 묻혔습니다. 순위를 바꾸고, 음량을 MAME 와 같은 조건에서 측정해
  보정했습니다.
- **특정 투수의 공이 MAME 보다 맞지 않았다** — 게임이 난수로 쓰는 `0x30c003`
  레지스터의 값 범위와 CPU 가 보는 VBLANK 길이가 MAME 와 달라, CPU 투수 AI 의
  구종 선택이 MAME 와 반대로 고정되어 있었습니다. 두 값의 기본을 MAME 호환으로
  바꾼 뒤, 시뮬레이션에서 투구 1–9 구의 구종·비행, 첫 투구 타격 가능 구간,
  번트, 두 번째 CPU 투수, 긴 경기 구간이 MAME 와 일치함을 확인했습니다.
- **68000 의 난수가 래스터에 위상 고정** — 프로그램 ROM 이 비디오 페치 뒤에서
  기다리면서 읽기 위상이 고정되었습니다. 프로그램 ROM 을 칩 내부로 옮겼습니다.
- **배포 `.mra` 의 스프라이트 색이 틀렸다** — `.mra` 생성기의 스프라이트 플레인
  순서가 뒤집혀 있었고 타일 영역 패딩 크기가 잘못되어 있었습니다. 고친 뒤
  로더 모델로 만든 이미지가 기준 이미지와 바이트 단위로 같고, 실기 화면도
  일치함을 확인했습니다.

## 감사의 말과 사용한 코드

먼저 **MAME 개발팀**에 깊이 감사드립니다. 이 코어의 메모리 맵, 클럭, 인터럽트,
화면 기하, 그래픽 디코드, DIP 기본값, 사운드 라우팅, 두 커스텀 칩의 동작은
모두 MAME 소스에서 배웠습니다. 수십 년에 걸친 보존과 문서화 작업이 없었다면
이 코어는 시작할 수 없었습니다.

- https://www.mamedev.org/
- https://github.com/mamedev/mame

### 코어에 포함된 서드파티 코드

| 이름 | 용도 | 저자 | 라이선스 | 출처 (링크 + 커밋) | 사용한 파일 | 수정 여부 |
|---|---|---|---|---|---|---|
| fx68k | 68000 메인 CPU | Jorge Cwik | GPL-3.0-only | [ijor/fx68k](https://github.com/ijor/fx68k) `0602ee4627b10f301298f2673d826cdd6baa9327` | `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem` | `fx68k.sv` 에 읽기 전용 디버그 포트 `dbg_d7` 추가 (동작 변경 없음, 파일 내 `// LOCAL:` 표시). 나머지 원본 그대로 |
| jt65c02 | 65C02 사운드 CPU | Jose Tejada (jotego) | GPL-3.0-or-later | [jotego/jtcores](https://github.com/jotego/jtcores) `modules/jt680x`, `62cacc840340ad1fe7d6be481d0f9bbebe835e7d` | `jt65c02*.v`, `65c02.vh`, `65c02_param.vh`, `65c02.uc` | 수정 없음. `65c02_param.vh` 와 `65c02.uc` 는 같은 커밋의 `ucode/65c02.yaml` 에서 jtframe 생성기로 만든 파일 |
| jt12 (jt03) + jt49 | YM2203 (FM + SSG) | Jose Tejada (jotego) | GPL-3.0 | [jotego/jt12](https://github.com/jotego/jt12) `4cf1c5b`, jt49: [jotego/jt49](https://github.com/jotego/jt49) `47301ed` | `jt03.v` 와 jt12/jt10/jt49 모듈 일체 | 있음 — `jt10.v`, `jt10_adpcm_drvA.v`, `jt12_top.v`, `jt12_kon.v`, `jt12_mmr.v`, `jt12_reg.v` 에 디버그 관측용 출력 포트만 추가 (기존 논리 변경 없음, 추가한 모든 줄에 `// LOCAL:` 표시). jt49 는 원본 그대로. `jt12_comb.v` 는 jt6295 쪽 사본을 씁니다 |
| jtopl | YM3812 (OPL2) | Jose Tejada (jotego) | GPL-3.0 | [jotego/jtopl](https://github.com/jotego/jtopl) `7ac0c81` | `jtopl2.v` 와 jtopl 모듈 일체 | 수정 없음 |
| jt6295 | OKI M6295 ADPCM | Jose Tejada (jotego) | GPL-3.0 | [jotego/jt6295](https://github.com/jotego/jt6295) `7d76b0be8cd8f85f3ae741178c9830b20e2071a1` | `jt6295*.v`, `jt12_comb.v` | 수정 없음 |
| MiSTer framework | HPS I/O, OSD, 스케일러, HDMI, 오디오 출력, 최상위 `sys_top` | MiSTer-devel 및 기여자 | 파일별 (대부분 GPL-2.0-or-later 또는 GPL-3.0-or-later, `sd_card.sv` 는 LGPL) | [MiSTer-devel/Template_MiSTer @ `54ac838e019d7fa07fbb40677a104cd6620d15c3` (2026-08-17, `sys/` 내용 일치로 식별)](https://github.com/MiSTer-devel/Template_MiSTer) | `sys/` 아래 파일 일체 | `sys.tcl` 의 경로 계산 두 줄만 변경 (동작 변경 없음) |

- **Jorge Cwik** 님, 사이클 단위로 정확한 68000 코어 fx68k 를 공개해 주셔서
  감사합니다.
- **Jose Tejada (jotego)** 님, 65C02·YM2203·YM3812·M6295 를 모두 jotego 님의
  코어로 쓸 수 있었습니다. 그리고 `jtcop` 이 같은 두 커스텀 칩과 같은 사운드
  보드를 이미 풀어 두었기에 이 기판의 해석을 빠르고 확실하게 대조할 수
  있었습니다. 감사합니다.
- **MiSTer-devel** 과 기여자 여러분, MiSTer 라는 플랫폼과 프레임워크에 감사드립니다.

### 참고한 MAME 소스

코드 주석에 `파일:줄` 로 출처를 남겼습니다. MAME 의 BSD-3-Clause 는 GPL 과
호환됩니다.

| MAME 파일 | 라이선스 | copyright-holders | 참고한 내용 |
|---|---|---|---|
| `src/mame/dataeast/stadhero.cpp` | BSD-3-Clause | Bryan McPhail | 메모리 맵, 클럭, 인터럽트, 화면, gfxdecode, DIP, 사운드 라우팅, ROM 구성, `0x30c003` 동작 |
| `src/mame/dataeast/decbac06.cpp` | BSD-3-Clause | Bryan McPhail, David Haywood | BAC06 레지스터 의미, 타일맵 주소 계산, 스크롤 |
| `src/mame/dataeast/decmxc06.cpp` | BSD-3-Clause | Bryan McPhail, David Haywood | MXC06 속성 디코드, 다중 폭 스프라이트 순회 (구조적으로 따름) |
| `src/mame/dataeast/dec0.cpp` | BSD-3-Clause | Bryan McPhail | 같은 세대 기판의 화면 타이밍, 열/행 스크롤 매핑 비교 |
| `src/devices/sound/ymfm_mame.h` | BSD-3-Clause | Aaron Giles | YM2203 FM/SSG 출력 게인 |
| `src/emu/screen.cpp` | BSD-3-Clause | Aaron Giles | `hpos()` 계산 방식 (난수 레지스터의 MAME 호환 모드) |
| `src/emu/drawgfx.cpp` | BSD-3-Clause | Nicola Salmoria, Aaron Giles | 투명 펜(pen 0) 처리 |

기판 레이아웃과 하드웨어 메모를 남겨 주신 **Guru** 님께도 감사드립니다.

### 사실 확인에만 참고한 자료 (코드 미사용)

- **jtcores** (`jtcop`, GPL-3.0-or-later, `62cacc8`) — `jtcop_bac06.v`,
  `jtcop_obj_draw.v`, `jtcop_snd.v` 등을 같은 칩의 독립적인 두 번째 해석으로
  읽었습니다. 비디오·글루 로직 파일은 코어에 들어 있지 않으며, DEC0 래스터
  상수와 칩 해석을 대조하는 데 썼습니다 (위 표의 jt65c02 는 같은 저장소에서
  가져온 별도 모듈입니다).
- **FBNeo** (`d_stadhero.cpp`) — M6295 클럭, GFX ROM 오프셋, DIP 조합, 68000 ROM
  인터리브, 사운드 게인 순서를 교차 확인하는 데만 읽었습니다. **FBNeo 의 코드는
  한 줄도 들어 있지 않습니다.**

## 라이선스

이 코어 전체는 **GPL-3.0** 으로 배포됩니다 (fx68k 가 GPL-3.0-only 이므로).
`LICENSE` 파일이 GPL-3.0 전문입니다. 서드파티 파일은 각자의 저작권·라이선스
헤더를 그대로 유지합니다.

**ROM 은 포함되어 있지 않습니다.** 정당하게 보유한 `stadhero` ROM 세트를
직접 준비해 주세요.

## 알려진 제한사항

- **MiSTer 전용입니다.** Analogue Pocket 버전은 아직 없습니다.
- **난수 레지스터(`0x30c003`)와 CPU 가 보는 VBLANK 길이는 MAME 의 동작을 따른
  값입니다.** 실제 PCB 가 이 값을 어떻게 만드는지는 확인되지 않았습니다. 투구·
  타격의 게임성은 MAME 와 일치하도록 맞췄고, OSD 의 Debug 페이지에서 다른
  후보(보드 래스터 기반)로 바꿔 볼 수 있습니다.
- **어트랙트 데모의 대진이 MAME 와 다를 수 있습니다.** 이 코어는 PCB 의 프레임
  주기(57.44 Hz)를 쓰고 MAME 는 58 Hz 로 가정하기 때문입니다. 실제 경기에는
  영향이 없습니다.
- **CPU 팀의 도루 동작은 MAME 와 대조하지 못했습니다.**
- **`ef19.3d` PROM 은 구현하지 않았습니다.** MAME 도 이 PROM 을 읽지 않으며,
  이 기판의 레이어 순서는 고정입니다.
- 검증은 MAME 와의 대조 및 MiSTer 실기 플레이를 기준으로 합니다. 원본 PCB 와
  직접 대조한 것은 아닙니다.
