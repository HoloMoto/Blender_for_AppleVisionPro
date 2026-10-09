# RealityMixerVisionPro（MIT）ベンダー

出典: https://github.com/fabio914/RealityMixerVisionPro  
依存 TCP: `../SwiftSocket`（同作者、MIT）

## Blender での使い方（合意）

1. iPad `Window` → **合わせ画像を表示**（印刷しない）
2. VP Immersive → **合わせ開始**（ImageTracking で iPad 画面を見る）
3. ロック後、合わせ画像を隠す
4. iPad が VP からの Mixed Reality 映像を受信（本ソースの MRC）

## 配線状況

| 部品 | 状態 |
|---|---|
| Sources（visionOS MRC サーバ／レンダラ） | このディレクトリに配置済 |
| SwiftSocket | `extern/SwiftSocket` |
| CMake への組込 | **次**（`WITH_VISIONOS_IMMERSIVE_SPACE` 時に Swift ソース追加） |
| iPad 受信 UI | **次**（`GHOST_IOSImmersive` を MRC クライアント化） |

合わせ画像の物理幅: RealityMixer デフォルトは 5cm。Blender 既存ビットマップは 0.18m。
MRC 接続時は **同一ビットマップ＋同一 physicalWidth** に揃えること。
