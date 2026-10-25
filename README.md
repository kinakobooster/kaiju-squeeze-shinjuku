# Kaiju Squeeze Shinjuku

巨大怪獣になって新宿のビルをスクイーズする、Webカメラで遊ぶGodot 4.6のゲーム。

## 遊び方

最初は身長30mの小さな怪獣です。ビルを潰すたびに大きくなり、つぶせるビルの高さ（身長の1.6倍まで）も上がっていきます。

| 動作 | 手の動き |
|---|---|
| 前進 / 後退 | 地面をつかんで引き寄せるように、素早く下へかく（素早く上へ押し返すと後退）。素早く動かした方向が効きます |
| 旋回 | 手を素早く横に動かす（スマホの画面をドラッグする感覚）。片手で上下に漕ぐと、その手の側へ曲がり、逆に漕ぐと反対へ曲がる |
| ビルを選ぶ | 手をパーにして少し止める（ビルがオレンジに光る。灰色のときは、まだ硬くて潰せない） |
| サクッ | 素早くグーにする |
| グジュウ〜 | ゆっくりグーにする。ビルは手を握った分だけ潰れます（ゲージはありません） |
| バチーン | 画面に向かって叩く、またはとても速く手を振り抜く |
| 両手スクイーズ | 両手で同じビルを握る、またはパーで左右から挟み込む |

カメラがない場合はマウスで遊べます: 左ボタン長押し=ゆっくり握る、Space=素早く握る、右ボタン=叩く、Shift=両手、WASD=移動、P=カメラ映像の表示切替（初期状態は非表示）、H=ヘルプ。

## ビルドと起動

```bash
./export_web.sh
```

```bash
python3 -m http.server 8060 -d build/web
```

ゲームの動作テスト（手の動きの合成データでサクッ・グジュウ・バチーン・前進後退・旋回を確認します）:

```bash
godot --headless --path . --fixed-fps 60 --script tests/play_test.gd
```

ブラウザで http://localhost:8060 を開きます（カメラは localhost か https でのみ使えます）。シングルスレッドでエクスポートしているので、COOP/COEP ヘッダーなしで itch.io などにそのまま置けます。

## 仕組み

- **手の検出** `web_shell/hand_tracking.js`: MediaPipe Hand Landmarker（tasks-vision 0.10.14、CDN から読み込み）がブラウザ上で両手の21点を検出し、`window.kaijuHands` に書き込みます。Godot 側（`scripts/hand_input.gd`）は `JavaScriptBridge` で毎フレームこれを読み取り、指先と手首の距離の比から手の開き具合（0=グー、1=パー）を計算します。
- **シルエット** `scripts/hand_silhouette.gd` と `shaders/hand_silhouette.gdshader`: 21点から手のひら・指・爪・前腕を白いマスクとして SubViewport に描き、それを黒い怪獣の手（緑のリムライトと鱗模様付き）として画面全体に合成します。握っている間は半透明になり、潰れていくビルが見えます。
- **街** `tools/bake_city.py` から `data/city.json` を生成: OpenStreetMap（Overpass API）の新宿駅周辺約2km四方のデータで、建物7600棟、道路、線路、公園、水面を含みます。高さは OSM の `height`、なければ `building:levels × 3.5m`、それもなければ面積と地区（西新宿は高層）から推定します。都庁など一部はランドマークの値で上書きしています。`scripts/city.gd` が建物の外形を押し出して160mごとのチャンクメッシュにまとめ、窓はシェーダーで描きます。
  - 生のOSMデータ（`tools/data/`）はリポジトリに含めていません。再生成するときは、Overpass API から bbox `35.682,139.688,35.700,139.712` の `way["building"]` を `tools/data/shinjuku_osm.json` に、道路・線路・公園・水面を `tools/data/shinjuku_lines.json` に保存してから `python3 tools/bake_city.py` を実行します。
- **スクイーズ** `shaders/building.gdshader`: 掴んだビルだけをチャンクから切り離して細かく分割し、頂点シェーダーで変形させます。握った高さを中心に絞り、押し出された分を上下に膨らませ、ぷるぷる揺らし、ビルごとに決まった色のジュースで染めます。両手のときは左右から潰れて横にはみ出します。
- **効果音** `tools/synth_sfx.py` から `audio/*.wav` を生成: すべて合成音です（下の調査メモを参照）。

## 調査メモ

**街並みデータ**
- [PLATEAU](https://www.mlit.go.jp/plateau/)（国交省の3D都市モデル、CityGML、LOD2）が最も正確ですが、23区のデータはGB単位でWeb向けには重すぎます。[PlateauKit](https://pypi.org/project/plateaukit/0.2.0/) で CityJSON に変換できます。
- [OpenStreetMap](https://wiki.openstreetmap.org/wiki/Organised_Editing/Activities/TomTom/Global_-_Building_Height_Imports/Japan_-_PLATEAU_Building_Height_Enrichment) は日本の建物外形の網羅性が高い一方、高さタグは一部にしかありません。今回の範囲では7925棟中、`height` が867棟、`building:levels` が1161棟でした。主要な高層ビルには付いているため、今回は OSM を採用し、残りは推定値で補っています。

**スクイーズ音の気持ちよさ**
- 潰す音は衝撃ではなく「圧力」です。頭で鳴らすのではなく、クリップ全体を通して溜めていくのが良いとされています（[morphic](https://morphic.com/resources/sounds/squish-sound-effect)）。そこで、握っている間はループ音のピッチを潰れ具合に応じて上げていきます。
- 粘る質感は「閉じ込められた空気の破裂音」と「糸を引いてちぎれる音」から生まれます（[slime SFX](https://morphic.com/resources/sounds/slime-sound-effects)）。そこで、下降するフォルマントのグレインとランダムな泡のポップ音を重ねています。
- ピッチを下げた湿った音は怪物っぽく聞こえます。大きいビルほどピッチを下げています。
- ゲームで「ジューシー」に感じさせるには、音を誇張し、視覚と重ね、低音と中音域を厚くします（[Smets & van der Spek 2021](https://research.tue.nl/en/publications/that-sounds-juicy-exploring-juicy-audio-effects-in-video-games/)、[GameAnalytics](https://www.gameanalytics.com/blog/squeezing-more-juice-out-of-your-game-design)）。そこで、画面の揺れ・ジュースの粒子・ビルの変形を音と同時に起こしています。

## クレジット

- 地図データ © OpenStreetMap contributors（ODbL）
- フォント: Dela Gothic One、M PLUS 1p（SIL Open Font License）
- 手の検出: Google MediaPipe（Apache 2.0）
