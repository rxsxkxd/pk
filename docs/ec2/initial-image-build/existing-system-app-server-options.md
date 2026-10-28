# 検討: 今の構成のアプリケーションサーバーの選択肢（Passenger・Puma・Unicorn・Pitchfork）

> 位置付け: 検討の整理。採用済みの設計ではない。[今の構成を AL2023 で作り直す検討](./existing-system-rebuild-on-al2023.md) のうち、Apache の後ろで Rails を動かすアプリケーションサーバーの選択肢を比べる。論点 M3（Passenger のバージョン）の判断の材料にもなる。**どれも動かして確かめてはいない**。
>
> 調査日: 2026-10-28（gem の版と、必要な Ruby・Rack の条件は RubyGems と各プロジェクトの変更履歴で確認した）

## 前提

| 項目 | 前提 |
|---|---|
| アプリ | Rails 4.2（4-2-stable）、Ruby 2.7.7。アプリの側を上げるとしても Rails 5.x まで、Ruby は 2.7 系 |
| 前段 | Apache は残す（HTTP/2、TLS、アクセス制限）。ALB は入れない |
| OS | Amazon Linux 2023 |
| 今の構成 | Apache に Passenger を組み込み（`mod_passenger`）、同じマシンで Rails のプロセスを動かしている |

## 結論

| # | 結論 |
|---|---|
| 1 | Rails 4.2・Ruby 2.7 で、**更新が続いているまま選べるのは Passenger だけ**。Puma と Unicorn は、修正がもう出ない古い版に留まれば使える。Pitchfork は Rails 4.2 では使えない |
| 2 | 緊急の対応としては、**Passenger の組み込み（今の構成）が第一の候補**。変わる量が一番小さい |
| 3 | Apache とアプリを別のマシンに分ける必要があるなら、**Passenger Standalone** が第一。アプリの動き方（プロセスのモデル、再起動）が今と変わらない |
| 4 | Pitchfork を使うには **Rails 5.0 以上**が要る（Rack 2.0 以上が要るため）。選ぶことが、そのまま Rails を 5.x に上げる決定になる |

## 比べる軸

| 軸 | 選択肢 |
|---|---|
| Apache とのつなぎ方 | 組み込む（同じマシンに限る） / Apache から転送する（`mod_proxy`。同じマシンでも別のマシンでもよい） |
| アプリケーションサーバー | Passenger / Puma / Unicorn / Pitchfork |

Passenger を Apache に組み込む形では、Passenger が自分で Rails のプロセスを起動し、同じマシンの中の通信（Unix ドメインソケット）で処理を渡す。**Apache・Passenger・Rails のプロセスは同じマシンになければならない**。別のマシンにあるアプリのプロセスに処理を振り分ける機能はない。Apache とアプリを分けるなら、Apache から転送する形（Passenger Standalone・Puma・Unicorn・Pitchfork）になる。

## Rails 4.2・Ruby 2.7 で使えるか

Rails 4.2 は Rack 1.6 を使う（actionpack 4.2.11.3 の依存が `rack ~> 1.6`）。これが一番効く制約である。

| 区分 | 候補 | Ruby 2.7 で使える版 | Rails 4.2（Rack 1.6）で動くか | 開発の状況 |
|---|---|---|---|---|
| **使えて、更新も続いている** | Passenger（Apache に組み込み） | 6.2.1（2026-10）まで。6.1 以降は Ruby 2.5.9 以上 | 動く（今の構成は 6.0.18） | 更新が続いている |
| | Passenger Standalone | 同上（同じ gem） | 動く見込み | 同上 |
| **古い版に留まれば使える** | Puma | **6.3.0〜6.6.1**。7.0 以降は Ruby 3.0 以上が要る | 6.3.0 以上なら動く（6.0〜6.2 は Rack 1.6 で動かず、6.3.0 で戻された） | 6 系は 6.6.1（2025-07）が最後で、7.0（2025-09）の後に 6 系の新しいリリースはない |
| | Unicorn | 6.1.0（2021-12） | 動く（Rails 4 の時代によく使われた） | 2021 年から更新がない |
| **使えない** | Pitchfork | 0.18.2（Ruby 2.5 以上） | **動かない**（Rack 2.0 以上が要る） | 更新が続いている（0.x 系） |

「古い版に留まれば使える」ものは、選んだ時点で修正がもう出ない版に固定される。Ruby 2.7 と Rails 4.2 を使い続ける限り、この状態は変わらない。

## Rails 5.x に上げた場合

| Rails（actionpack） | Rack の依存 | Pitchfork | Puma |
|---|---|---|---|
| 4.2.11.3 | `rack ~> 1.6` | 使えない | 6.3.0〜6.6.1 |
| **5.0.0** | **`rack ~> 2.0`** | **使える（最低ライン）** | 6.0.0〜6.6.1（Rack 1.6 の制約がなくなる） |
| 5.1.7 | `rack ~> 2.0` | 使える | 同上 |
| 5.2.8.1 | `rack ~> 2.0, >= 2.0.8` | 使える | 同上 |

- Pitchfork は Ruby 2.5 以上なので、Ruby 2.7 のままでよい
- Rails 5.x の作業の大半は、4.2 から 5.0 に上げる段階にある（[今の構成の検討の補足](./existing-system-rebuild-on-al2023.md#補足-アプリの側を-rails-5x-まで上げたとき懸念がどこまで消えるか)）
- Ruby 2.7 で使える Puma が 6.6.1 までである点は変わらない

## 比較

| 項目 | Passenger（組み込み） | Passenger Standalone | Puma 6.6 | Unicorn 6.1 | Pitchfork |
|---|---|---|---|---|---|
| Rails 4.2 で使えるか | 使える | 使える | 6.3.0 以上なら使える | 使える | 使えない（Rails 5.0 以上） |
| 今の構成からの変更 | **最小**（Passenger を作り直すだけ） | 中（Apache の設定を `mod_proxy` での転送に変え、起動の仕組みを足す） | 大（Gemfile、設定、起動の仕組み、再起動の手順） | 大（同左） | 大（同左と、Rails 5.x への更新） |
| Apache と別のマシンにできるか | できない | できる | できる | できる | できる |
| プロセスの管理 | Apache と一緒に起動・停止 | systemd のユニットを作る | systemd のユニットを作る | systemd のユニットを作る | systemd のユニットを作る |
| 処理のモデル | 複数のプロセス（無料版はスレッドを使わない） | 同左 | プロセスとスレッド。**Rails 4.2 のアプリや古い gem がスレッドに安全とは限らない**ので、まずは 1 プロセス 1 スレッドで今と同じ形にする | 複数のプロセス | 複数のプロセス |
| 前段の要件 | なし | Apache から転送 | Apache から転送 | 遅い利用者からの通信を前段でまとめて受ける必要があり、作者は nginx を勧めている。Apache で足りるかは要確認 | Unicorn と同じ考え方（README に「速い利用者向け」とある）。Apache で足りるかは要確認 |
| 再起動のしかた | `passenger-config restart-app` など | 同左 | `pumactl phased-restart` など | シグナル（`USR2` など） | シグナルなど |
| AL2023 で気を付けること | `mod_passenger` のビルド | 初回の起動で、内部で使う nginx を取得またはビルドするので、土台を作るときに済ませておく | なし（C 拡張が小さい） | なし | なし |
| 成熟度 | 長く使われている | 同左 | 長く使われている | 長く使われている（更新は止まっている） | 版がまだ 0.x 系 |

## メモリの特性とプロセスの管理

各プロジェクトの文書と設定の項目からの整理で、数値は測っていない。Pitchfork は Rails 4.2 では使えない（Rails 5.0 以上）が、比べるために載せる。

### メモリの特性

| 候補 | 同時に処理できる数 | メモリの使い方 | メモリの増加への備え |
|---|---|---|---|
| Passenger（組み込み / Standalone。無料版） | プロセスの数（1 プロセスで 1 リクエスト。スレッドは有料版だけ） | 既定（`PassengerSpawnMethod smart`）では、アプリを読み込んだプロセスから fork するので、読み込み済みの部分をプロセス間で共有できる（copy-on-write）。プロセスの数は負荷に合わせて増減する（上限 `PassengerMaxPoolSize`、既定 6。使われないプロセスは `PassengerPoolIdleTime`、既定 300 秒で止まる）。Passenger 自身のプロセス（Watchdog・Core）が別にある | 一定のリクエスト数でプロセスを入れ替える（`PassengerMaxRequests`）。プロセスごとのメモリの上限（`PassengerMemoryLimit`）は**有料版だけ** |
| Puma 6.6（クラスターモード） | ワーカーの数 × スレッドの数 | スレッドはプロセスの中でメモリを共有するので、同じ同時処理数ならプロセスだけの形より少なくて済む。`preload_app!` でワーカー間の共有もできる。`fork_worker`（5.0 から。実験的な機能）で、温まったワーカーから fork し直して共有を増やせる。**Rails 4.2 ではまず 1 スレッドで動かす前提**なので、スレッドによる節約は当てにしない | 組み込みの上限はない（ワーカーを入れ替える外部の gem に頼る） |
| Unicorn 6.1 | ワーカーの数（1 ワーカーで 1 リクエスト） | `preload_app true` で、アプリを読み込んだマスターから fork して共有する。ワーカーの数は固定（設定の `worker_processes`） | 組み込みの上限はない（外部の gem に頼る）。処理が `timeout`（既定 60 秒）を超えたワーカーは止めて入れ替える |
| Pitchfork | ワーカーの数（1 ワーカーで 1 リクエスト） | **リフォーク**: 温まったワーカーを新しい雛形（mold）にして、そこから fork し直す。動いている間に読み込まれた部分も共有でき、README では「スレッドと比べてわずかに多い程度のメモリで済む」としている。アプリが fork に安全である必要がある（接続などを fork の後に作り直す） | リフォークのたびにワーカーが入れ替わる。処理時間の上限（`timeout`）を超えたワーカーは止めて入れ替える |

### プロセスの管理

| 候補 | プロセスの構成 | 誰が起動・監視するか | アプリの再起動・入れ替え | systemd での扱い |
|---|---|---|---|---|
| Passenger（組み込み） | Apache ＋ Passenger の Watchdog・Core ＋ アプリのプロセス | Apache と一緒に起動・停止する。アプリのプロセスは Passenger が起動・監視し、落ちたら起動し直す | `passenger-config restart-app` か `tmp/restart.txt`。無料版はプロセスを入れ替える間に待ちが出る（順番に入れ替える rolling restart は有料版だけ） | Apache のユニット（`httpd.service`）だけ |
| Passenger Standalone | Passenger（内部の nginx か組み込みの HTTP の処理）＋ アプリのプロセス | `passenger start` で起動。アプリのプロセスは Passenger が起動・監視する | 同上 | ユニットを作る |
| Puma 6.6 | マスター ＋ ワーカー | マスターがワーカーを起動・監視し、落ちたら起動し直す | `pumactl restart`（全体の再起動）、`pumactl phased-restart`（ワーカーを順番に入れ替える。`preload_app!` とは併用できない） | ユニットを作る。Puma は systemd との連携（起動の通知）に対応している |
| Unicorn 6.1 | マスター ＋ ワーカー | マスターがワーカーを起動・監視し、落ちたり `timeout` を超えたりしたら入れ替える | `USR2` で新しいマスターを起動し、確認してから古いマスターに `QUIT`（止めずに入れ替える）。`HUP` で設定の読み直し、`TTIN` / `TTOU` でワーカーの数の増減 | ユニットを作る。`USR2` での入れ替えではマスターのプロセス番号が変わるので、systemd の設定に工夫が要る |
| Pitchfork | モニター ＋ 雛形（mold）＋ ワーカー | モニターがワーカーを起動・監視し、落ちたら起動し直す | `USR1` で全体を起動し直す（新しい雛形を作り、ワーカーを順に入れ替える）、`USR2` で手動のリフォーク。`TTIN` / `TTOU` でワーカーの数の増減 | ユニットを作る |

今の構成（Passenger の組み込み）は、プロセスの管理を Apache と Passenger に任せていて、アプリのための systemd のユニットがない。ほかの候補に移ると、ユニットと、再起動・入れ替えの手順を新しく用意することになる。

## 判断の材料

| 点 | 内容 |
|---|---|
| 緊急の対応なら Passenger の組み込み | 変わる量が一番小さく、Ruby 2.7 に対応したまま更新が続いている唯一の候補。6.0.18 のままでビルドできなければ、6.0.27（6.0 系の最後）か 6.2 系に上げる道がある |
| 分ける理由がなければ、ほかに移る利点は小さい | Apache とアプリを分けると、通信の経路と起動の仕組みが増える。OS でのアクセス制限は Apache のマシンで行い、アプリのマシンには Apache からの通信だけを通す設定が要る |
| 分けるなら Passenger Standalone | 同じ Passenger なので、アプリの動き方が今と変わらない |
| Puma 6.6 は次の候補 | 動く見込みはあるが、6 系は更新が止まっている可能性があり、スレッドに安全かの確認も要る |
| Unicorn は外してよい | 更新が止まっていて、前段の要件もある |
| Pitchfork は Rails 5.x に上げるときだけの候補 | Rails 4.2 では使えない。版がまだ 0.x 系で、前段の要件もある |

## 決めること

| # | 論点 | 選択肢 |
|---|---|---|
| S1 | Apache とアプリを別のマシンに分けるか | 分けない（Passenger の組み込み） / 分ける（Passenger Standalone が第一） |
| S2 | Passenger の版（[今の構成の検討](./existing-system-rebuild-on-al2023.md) の M3） | 6.0.18（そのまま） / 6.0.27（6.0 系の最後） / 6.2 系（更新が続いている） |
| S3 | Rails を 5.x に上げるか（同じく M8） | 上げるなら、Pitchfork も候補に入り、Puma の版の制約がゆるむ |

## 未確認の点

| # | 点 |
|---|---|
| 1 | Passenger 6.2 系が、Rails 4.2・Ruby 2.7.7 のアプリを問題なく動かせるか。検証のときに 6.0.18 と並べて確かめる |
| 2 | Passenger Standalone が内部で使う nginx を、AL2023 で取得できるか（ビルドになるなら、そのための道具が要る） |
| 3 | Unicorn・Pitchfork の前段として、Apache（`mod_proxy`）で足りるか |
| 4 | アプリと gem がスレッドに安全か（Puma でスレッドを使う場合） |

## 参考

- [passenger - RubyGems](https://rubygems.org/gems/passenger)（6.0.27: 2025-04、6.1 以降は Ruby 2.5.9 以上、6.2.1: 2026-10）
- [puma - RubyGems](https://rubygems.org/gems/puma)、[Puma の変更履歴](https://github.com/puma/puma/blob/master/History.md)（6.3.0 で Rack 1.6 との互換を戻した、7.0.0 で最低の Ruby を 3.0 にした）
- [unicorn - RubyGems](https://rubygems.org/gems/unicorn)（6.1.0: 2021-12）
- [pitchfork - RubyGems](https://rubygems.org/gems/pitchfork)、[Shopify/pitchfork](https://github.com/Shopify/pitchfork)（Rack 2.0 以上、Ruby 2.5 以上）
- [actionpack - RubyGems](https://rubygems.org/gems/actionpack)（4.2 は `rack ~> 1.6`、5.0 以降は `rack ~> 2.0`）
- [Phusion Passenger の設定の文書](https://www.phusionpassenger.com/docs/references/config_reference/apache/)（`PassengerSpawnMethod`、`PassengerMaxPoolSize`、`PassengerPoolIdleTime`、`PassengerMaxRequests`、有料版だけの `PassengerMemoryLimit` と rolling restart）
- [Pitchfork の README](https://github.com/Shopify/pitchfork)、[REFORKING](https://github.com/Shopify/pitchfork/blob/master/docs/REFORKING.md)、[SIGNALS](https://github.com/Shopify/pitchfork/blob/master/docs/SIGNALS.md)、[FORK_SAFETY](https://github.com/Shopify/pitchfork/blob/master/docs/FORK_SAFETY.md)
- [Unicorn の SIGNALS](https://yhbt.net/unicorn/SIGNALS.html)
