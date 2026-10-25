# Kaiju Squeeze Shinjuku

巨大怪獣になって新宿のビルをスクイーズする、Webカメラで遊ぶGodot 4.6のゲーム。

## 遊び方

両手でいいねをして上下に振り、前に歩き出すとスタートです。最初は身長30mの小さな怪獣です。ビルを潰すたびに少しずつ大きくなり、つぶせるビルの高さ（身長の1.6倍まで）も上がっていきます。腕が届くのは「16m + 身長の半分」までで、手を出すとカメラが手元を見下ろし、手の届く範囲の内側だけがカラフルに、外側はモノクロになります。狙ったビルには赤い照準と「にぎれ！」が付きます。スタートは新宿御苑の北の端です。大きくなると、歩くだけで小さなビルを踏みつぶせます。地面やビルに落ちる自分の体と手の影で、大きさと手の届く範囲がわかります。

| 動作 | 手の動き |
|---|---|
| 前進 | 両手でいいね（親指を立てる）をして、上下に振る |
| 旋回 | 片手だけいいねをして揺らす。右手なら右へ、左手なら左へ曲がる |
| ねらう | いいね以外の手をパーにして止めると、手のひらに魔眼が開きます。手はだんだん大きくなり（最大2.5倍、届く範囲も広がる）、手に覆われた潰せるビルが全部赤く震え上がります。握ると全部まとめてスクイーズ |
| サクッ | 素早くグーにする |
| グジュウ〜 | ゆっくりグーにする。ビルは手を握った分だけ潰れます |
| プチッ | 親指と人差し指でつまむ（ほかの指は立てたまま） |
| バチーン / ドドド | 画面に向かって叩く、またはとても速く手を振り抜く。手と腕の影の下にある、自分の半分以下の高さのビルをまとめて潰します |
| 両手スクイーズ | 両手で同じビルを握る、またはパーで左右から挟み込む |
| ざらざら | 潰したビルの跡地に残った銀のビーズを、手でなでる |

**アイテム**: ときどき、目の前に光る星のアイテムが出ます。歩いて近づくか手で触ると取れます。

| アイテム | 効果 |
|---|---|
| ビーム（15秒） | 口を大きく開けるとビームが出ます。顔を動かすと振り回せて、当たったビルは星になって弾けます |
| クロー（20秒） | 爪が長く伸びて、腕を振ったとき（叩くとき）のリーチが1.5倍になります |
| ミダス（15秒） | いいね移動が超高速になり、ぶつかったビルはどんな高さでも全部、金のビーズになります |
| スマイル（15秒） | 笑顔になると、画面の真ん中のビルが凍りつきます。凍ったビルを握ると、きらきら・しゃりしゃりと鳴ります |

ビームとスマイルは顔の動きを使うので、カメラに顔も映してください（MediaPipe Face Landmarker で、口の開き・笑顔・鼻の位置を読み取っています）。

**3分後、身長500mの「せいぎの宇宙人」がやってきてボクシング勝負になります。とても強いので、1周目はたぶん負けます。**

- 宇宙人が大きく振りかぶると、画面に手の形の目印が出ます。パンチが届く瞬間に、その手の形に自分の手を合わせると受け止めてガードできます。
- 宇宙人の体を叩く（画面に向かって手を突き出す）と反撃できます。振りかぶっている最中に叩くと1.5倍のダメージです。
- 自分には体力がありません。殴られるたびに身長が「6m + 身長の10%」ずつ縮み、15mを下回るとゲームオーバーです。宇宙人はワンツーの連続パンチも打ってきます。
- 大きいほど有利です。与えるダメージが大きくなり、縮んでも余裕があります（30mだと2発、150mでも10発で負けます）。それまでにたくさん潰して大きくなっておきましょう。
- 宇宙人の体力をゼロにすると、ひざをついて「握れ！！」と出ます。その上でパーにしてから握ると「ぎゅう〜」と少しずつ潰れていくので、何度も握りつぶせば勝利です。
- 終わったら、Rキーか両手をパーにして少し待つと、もう一度遊べます。
- URLに `?boss=10` を付けると、10秒後に宇宙人が来ます（すぐ戦いたいとき用）。

手はカメラとの距離に関係なく、いつも同じ大きさで描かれます。

カメラがない場合はマウスで遊べます: 左ボタン長押し=ゆっくり握る、Space=素早く握る、Q=つまむ、右ボタン=叩く、B=口を開ける（ビーム）、F=笑顔、T=いいね、Shift=両手、WASD=移動、P=カメラ映像の表示切替（初期状態は非表示）、H=ヘルプ。

## ビルドと起動

```bash
./export_web.sh
```

```bash
python3 -m http.server 8060 -d build/web
```

ゲームの動作テスト（手の動きの合成データで、破壊・いいね移動・ビーズ・宇宙人戦を確認します）:

```bash
godot --headless --path . --fixed-fps 60 --script tests/play_test.gd
```

```bash
godot --headless --path . --fixed-fps 60 --script tests/boss_test.gd
```

ブラウザで http://localhost:8060 を開きます（カメラは localhost か https でのみ使えます）。シングルスレッドでエクスポートしているので、COOP/COEP ヘッダーなしで itch.io などにそのまま置けます。

## 仕組み

- **手の検出** `web_shell/hand_tracking.js`: カメラに 640×360・60fps を要求し、新しいフレームが来るたびに MediaPipe Hand Landmarker（tasks-vision 0.10.14、CDN から読み込み）がブラウザ上で両手の21点を検出し、`window.kaijuHands` に書き込みます。Godot 側（`scripts/hand_input.gd`）は `JavaScriptBridge` で毎フレームこれを読み取り、指先と手首の距離の比から手の開き具合（0=グー、1=パー）を計算します。
- **シルエット** `scripts/hand_silhouette.gd` と `shaders/hand_silhouette.gdshader`: 21点から手のひら・指・爪・前腕を白いマスクとして SubViewport に描き、それを黒い怪獣の手（緑のリムライトと鱗模様付き）として画面全体に合成します。握っている間は半透明になり、潰れていくビルが見えます。
- **街** `tools/bake_city.py` から `data/city.json` を生成: OpenStreetMap（Overpass API）の新宿駅周辺約2km四方のデータで、建物7600棟、道路、線路、公園、水面を含みます。高さは OSM の `height`、なければ `building:levels × 3.5m`、それもなければ面積と地区（西新宿は高層）から推定します。都庁など一部はランドマークの値で上書きしています。`scripts/city.gd` が建物の外形を押し出して160mごとのチャンクメッシュにまとめ、窓はシェーダーで描きます。
  - 生のOSMデータ（`tools/data/`）はリポジトリに含めていません。再生成するときは、Overpass API から bbox `35.682,139.688,35.700,139.712` の `way["building"]` を `tools/data/shinjuku_osm.json` に、道路・線路・公園・水面を `tools/data/shinjuku_lines.json` に保存してから `python3 tools/bake_city.py` を実行します。
- **スクイーズ** `shaders/building.gdshader`: 掴んだビルだけをチャンクから切り離して細かく分割し、頂点シェーダーで変形させます。握った高さを中心に絞り、押し出された分を上下に膨らませ、ぷるぷる揺らし、ビルごとに決まった色のジュースで染めます。両手のときは左右から潰れて横にはみ出します。
- **影** `shaders/kaiju_shadow.gdshaderinc`: 体と両手の影を、地面とビルのシェーダーで真上から投影しています（Web 用の Compatibility レンダラーにはデカールがないため）。
- **効果音** `tools/synth_sfx.py` から `audio/*.wav` を生成した合成音（下の調査メモを参照）に、`audio/samples/` の録音を重ねています。

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
- 効果音 `audio/samples/`: floraphonic「slime squish 4」、mrstokes302「squeeze plastic bottle」、freesound_community「fart squeeze」（Pixabay）。`squish_short.mp3` と `squish_long.mp3` は ElevenLabs で生成
