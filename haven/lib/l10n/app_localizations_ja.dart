// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appearanceTitle => '外観';

  @override
  String get appearanceThemeHeader => 'テーマ';

  @override
  String get appearanceThemeSystem => 'システムの設定に合わせる';

  @override
  String get appearanceThemeSystemSubtitle => 'デバイスの設定に従います';

  @override
  String get appearanceThemeLight => 'ライト';

  @override
  String get appearanceThemeLightSubtitle => '常にライトテーマを使用します';

  @override
  String get appearanceThemeDark => 'ダーク';

  @override
  String get appearanceThemeDarkSubtitle => '常にダークテーマを使用します';

  @override
  String get appearanceLanguageTitle => '言語';

  @override
  String get languageSystemDefault => 'システムの設定に合わせる';

  @override
  String get commonTryAgain => '再試行';

  @override
  String get commonDismiss => '閉じる';

  @override
  String get commonSettings => '設定';

  @override
  String get commonInvitations => '招待';

  @override
  String commonPendingInvitations(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '保留中の招待$count件',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => '戻る';

  @override
  String get commonContinue => '続ける';

  @override
  String get commonSkip => 'スキップ';

  @override
  String get commonRetry => '再試行';

  @override
  String onboardingStepOf(int current, int total) {
    return 'ステップ $current / $total';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'あなたの位置情報を、共有したい相手だけに、プライベートに共有しましょう。';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'だけ';

  @override
  String get onboardingWelcomeCta => 'はじめる';

  @override
  String get onboardingValuePropsTitle => 'Haven が選ばれる理由';

  @override
  String get onboardingValueProp1Title => 'あなたを見られるのはサークルのメンバーだけ';

  @override
  String get onboardingValueProp1Body =>
      '位置情報は端末を離れる前にこの端末上で暗号化されるため、読み取れるのはあなたが選んだサークルだけです。Haven も含め、ほかの誰にも読めません。Haven はオープンソースなので、そのことは誰でも確認できます。';

  @override
  String get onboardingValueProp2Title => '誰にも止められない';

  @override
  String get onboardingValueProp2Body =>
      'Haven には中央サーバーがありません。暗号化されたメッセージは、あなた自身が選べる分散型のリレーのネットワークを通じて届くため、特定の組織が単独でサービスを止めることはできません。';

  @override
  String get onboardingValueProp3Title => 'アカウントは不要';

  @override
  String get onboardingValueProp3Body =>
      'メールアドレスも電話番号も、登録も不要です。Haven はあなたの端末の中だけに存在するプライベートな識別情報を作成します。実際のあなたと結びつくものは一切ありません。';

  @override
  String get onboardingCreateIdentityTitle => '識別情報を作成';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven は、この端末の中だけに存在するプライベートな識別情報を作成します。これは、サークルのメンバーがあなたを見分けるためのものです。';

  @override
  String get onboardingCreateIdentityWarning =>
      'この端末を紛失したりアプリを削除したりすると、識別情報は失われます。Haven がそれを復元する方法はありません。';

  @override
  String get onboardingCreateIdentityCta => '識別情報を作成';

  @override
  String get onboardingCreateIdentityLoading => '準備しています…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'すでに鍵をお持ちですか？';

  @override
  String get onboardingCreateIdentityImportLink => '代わりにインポートする';

  @override
  String get onboardingCreateIdentityError => '識別情報の作成中に問題が発生しました。もう一度お試しください。';

  @override
  String get onboardingImportTitle => '既存の鍵をインポート';

  @override
  String get onboardingImportBody => 'ほかの Haven 対応アプリでバックアップした秘密鍵を貼り付けてください。';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'インポート';

  @override
  String get onboardingImportLoading => 'インポートしています…';

  @override
  String get onboardingImportInvalid =>
      '有効なバックアップ鍵ではないようです。ご確認のうえ、もう一度お試しください。';

  @override
  String get onboardingImportError => 'その鍵をインポートできませんでした。ご確認のうえ、もう一度お試しください。';

  @override
  String get onboardingDisplayNameTitle => '名前を決める';

  @override
  String get onboardingDisplayNameBody =>
      'この名前は、あなたがサークルへの招待を承認した相手にだけ表示されます。招待は公開鍵を使って送られるため、あなたが承認するまで名前は隠されたままです。';

  @override
  String get onboardingDisplayNameHint => '例: アレックス';

  @override
  String get onboardingDisplayNameError => 'その名前を保存できませんでした。もう一度お試しください。';

  @override
  String get onboardingReadyTitle => '準備が整いました';

  @override
  String get onboardingReadyBody =>
      'Haven は「サークル」という単位で構成されています。サークルとは、信頼できる相手と位置情報を共有する小さなプライベートグループです。最初のサークルを作成するか、知り合いからの招待を待ちましょう。';

  @override
  String get onboardingReadyCta => 'Haven を始める';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonOpenSettings => '設定を開く';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsIdentityTitle => '識別情報';

  @override
  String get settingsIdentitySubtitle => 'プロフィール、鍵、写真の共有';

  @override
  String get settingsRelaysTitle => 'リレー';

  @override
  String get settingsRelaysSubtitle => '招待があなたに届く経路';

  @override
  String get settingsLocationTitle => '位置情報';

  @override
  String get settingsLocationSubtitle => 'バックグラウンド共有と権限';

  @override
  String get settingsMapStyleTitle => '地図のスタイル';

  @override
  String get settingsAppearanceSubtitle => 'テーマと言語';

  @override
  String get settingsAboutTitle => 'このアプリについて';

  @override
  String get settingsDebugOverlayTitle => 'デバッグログのオーバーレイ';

  @override
  String get settingsDebugOverlaySubtitle => 'ログ出力を画面に表示します';

  @override
  String get relaySettingsTitle => 'リレー';

  @override
  String get relaySettingsCheckRelaysTooltip => 'リレーを確認';

  @override
  String get relaySettingsNoIdentityTitle => '識別情報がありません';

  @override
  String get relaySettingsNoIdentityMessage => 'リレーを管理するには、まず識別情報を作成してください。';

  @override
  String get relaySettingsLoadIdentityError => '識別情報を読み込めませんでした。';

  @override
  String get relaySettingsInboxTitle => '受信トレイのリレー';

  @override
  String get relaySettingsInboxSubtitle => 'kind 10050。招待があなたに届く経路です';

  @override
  String get relaySettingsKeyPackageTitle => 'KeyPackage リレー';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051。招待者があなたの暗号鍵を見つける経路です';

  @override
  String get relaySettingsLoadRelaysError => 'リレーを読み込めませんでした。';

  @override
  String get relaySettingsAddRelay => 'リレーを追加';

  @override
  String get relaySettingsRestoreDefaults => 'デフォルトに戻す';

  @override
  String get relaySettingsAddRelayError => 'リレーを追加できませんでした。';

  @override
  String get relaySettingsRemoveRelayError => 'リレーを削除できませんでした。';

  @override
  String get relaySettingsRestoreTitle => 'デフォルトのリレーに戻しますか？';

  @override
  String relaySettingsRestoreBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '現在の$count件のリレーが Haven のデフォルトに置き換えられます。この操作は元に戻せません。',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => '戻す';

  @override
  String get relaySettingsRestoreSuccess => 'デフォルトに戻しました。';

  @override
  String get relaySettingsRestoreError => 'デフォルトに戻せませんでした。';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return '$url を削除';
  }

  @override
  String get relaySettingsStatusConnected => '接続済み';

  @override
  String get relaySettingsStatusChecking => '確認中';

  @override
  String get relaySettingsStatusUnreachable => '接続できません';

  @override
  String get relaySettingsStatusNotChecked => '未確認';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'リレーの状態: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'リレーが設定されていません';

  @override
  String get relaySettingsEmptyMessage =>
      'ほかの人があなたに連絡できるよう、リレーが少なくとも1件必要です。下をタップして Haven のデフォルトに戻してください。';

  @override
  String get relaySettingsExplainerSemantics => 'Haven のリレーの仕組み';

  @override
  String get relaySettingsExplainerHeading => '仕組み';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven には中央サーバーがありません。2つのオープンな技術の上で動いています。Nostr は、誰でも運用できる「リレー」と呼ばれる独立したサーバーのネットワークです。リレーはあなたのメッセージを受け取り、一時的に保管し、連絡先が要求したときに渡します。どのリレーも不可欠ではないため、1つがオフラインになってもほかのリレーが機能し続けます。また、リレーが提出を求められうるものは、常に暗号化されたデータだけです。';

  @override
  String get relaySettingsExplainerMarmot =>
      'Marmot プロトコルは、MLS（Messaging Layer Security）という標準を用いて、メッセージが端末を離れる前にこの端末上で暗号化します。各サークルはそれぞれ固有の鍵を持つ独立した暗号化グループであり、別々のサークルが互いに結びつけられることはありません。これらの鍵は時間とともに更新され続けます。これは前方秘匿性（forward secrecy）と呼ばれる性質で、たとえ後から鍵が漏れても、それ以前のメッセージを解読することはできません。';

  @override
  String get relaySettingsExplainerMetadata =>
      'このため、リレーがあなたの位置情報、メッセージ、サークルのメンバー、あるいはそれらのメッセージ上のあなたの識別情報を知ることはありません。各メッセージは、その都度新しい使い捨ての送信アドレスから公開されるため、メッセージの中にあなたのアカウントと結びつくものはありません。ただし、リレーは一部のメタデータは見ることができます。サークルごとのランダムなタグ、通信のタイミングとサイズ、そしてあなたが接続するネットワークアドレスです。';

  @override
  String get relaySettingsExplainerInboxTerm => '受信トレイのリレー';

  @override
  String get relaySettingsExplainerInboxBody =>
      'は、あなたのメールボックスにあたります。サークルへの招待が、それ自体も暗号化されたうえで届けられ、あなたが受け取れる場所です。誰かがあなたを招待するには、これらのリレーのいずれかに到達できる必要があります。';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'KeyPackage リレー';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      'は、共有しても安全な公開鍵の小さなまとまりを公開しておく場所です。あなたのアカウントを知っている人が、サークルに追加するためにこれらのリレーから取得します。';

  @override
  String get relaySettingsExplainerOwnRelayTerm => '自分のリレーを使う。';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' 各サークルも独自のリレーリストを持ち、メンバーが参加するときに全員と共有されます。サークルの継続的な暗号化された更新が流れるのは、あなたの受信トレイではなく、このリストです。そのため、公開リレーを避けたい場合は、自分のリレーを運用してサークルをそこに向けることができます。全員が参加したあとは、そのサークルの通信をそのリレーだけで流すことができます。';

  @override
  String get relaySettingsExplainerReachabilityTerm => '注意点は到達性です。';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' すべてのメンバーがそのリレーに接続できる必要があります。また、最初に誰かを招待するときは、お互いが到達できるリレーが2人の間に必要です（たとえば、全員の受信トレイと KeyPackage のリレーとして同じプライベートリレーを指定する、など）。プライベートリレーも、ほかのリレーと同じく暗号化された通信とそのタイミングは見えます。違いは、誰が運用するかをあなたが管理できる点だけです。';

  @override
  String get relaySettingsExplainerFooter =>
      'どちらのリストでも、いつでもリレーを追加・削除できます。リレーが多いほどあなたに連絡しやすくなり、少ないほど暗号化された通信の経路をより自分で管理できます。';

  @override
  String get locationSettingsTitle => '位置情報';

  @override
  String get locationSettingsDisabledSnack => 'バックグラウンド共有をオフにしました';

  @override
  String get locationSettingsEnabledSnack => 'バックグラウンド共有をオンにしました';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'バックグラウンド共有を Android が継続するには通知が必要です。今はオフのままです。オンにするには Haven の通知を許可してください。';

  @override
  String get locationSettingsBatteryOptSnack =>
      'オンになりました。一部の端末では、バッテリー最適化により共有が一時停止することがあります。確実に動かすには、Haven をバッテリー最適化の対象から除外してください。';

  @override
  String get locationSettingsErrorSnack => '問題が発生しました';

  @override
  String get locationSettingsIntro =>
      'バックグラウンド共有がオンのとき、Haven を閉じていても、サークルのメンバーはあなたの現在地をリアルタイムで見続けられます。';

  @override
  String get locationSettingsToggleTitle => 'バックグラウンドで共有';

  @override
  String get locationSettingsToggleSubtitle => 'アプリを閉じても共有を続けます';

  @override
  String get locationSettingsIosLimitedNote =>
      'バックグラウンドでは制限されています。設定で Haven の位置情報を「常に許可」にしてください';

  @override
  String get locationSettingsAndroidHeader => '確実に動かすためのOS設定';

  @override
  String get locationSettingsAndroidNotification =>
      'Android がバックグラウンドサービスを維持できるよう、Haven には常駐の通知が必要です。通知の権限を拒否した場合は、設定を開いて Haven の通知を許可してください。';

  @override
  String get locationSettingsAndroidBattery =>
      'バックグラウンド共有を確実にするため、Haven をバッテリー最適化の対象からも除外してください。設定 → アプリ → Haven → バッテリー → 常に許可 と進みます。';

  @override
  String get locationSettingsAndroidVendors =>
      'Samsung 端末では、Haven を「スリープ状態のアプリ」から外してください（デバイスケア → バッテリー → バックグラウンドでの使用制限）。Xiaomi 端末では、Haven の自動起動を有効にしてください。';

  @override
  String get locationSettingsIosGuidance =>
      'バックグラウンドで継続的に共有するには、設定で Haven の位置情報を「常に許可」にしてください。iOS では、アプリがバックグラウンドで位置情報を使用している間、ステータスバーに青い表示が出ます。';

  @override
  String get mapStyleTitle => '地図のスタイル';

  @override
  String get mapStyleMinimalTitle => 'ミニマル';

  @override
  String get mapStyleMinimalSubtitle => 'ライト／ダークのテーマに合わせた、落ち着いたシンプルな地図';

  @override
  String get mapStyleDetailedTitle => '詳細';

  @override
  String get mapStyleDetailedSubtitle => 'フルカラーの道路、ラベル、場所を表示します';

  @override
  String get mapStyleOutdoorsTitle => 'アウトドア';

  @override
  String get mapStyleOutdoorsSubtitle => '陰影のある地形に登山道や公園を表示します';

  @override
  String get mapStylePreviewHeader => 'プレビュー';

  @override
  String get mapStylePreviewCity => '都市';

  @override
  String get mapStylePreviewNature => '自然';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return '地図のプレビュー（$scene）: $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics => 'このビルドでは地図のプレビューを利用できません';

  @override
  String get mapStylePreviewUnavailableLabel => 'ライブプレビューはリリースビルドで表示されます';

  @override
  String get aboutTitle => 'このアプリについて';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline => 'プライベートで、検閲に強い位置情報共有。';

  @override
  String get aboutLicensesTitle => 'オープンソースライセンス';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => '地図の問題を報告';

  @override
  String get aboutSupportOsm => 'OpenStreetMap を支援する';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\n地図データは ODbL に基づいて提供されています';

  @override
  String get aboutLinkOpenError => 'リンクを開けませんでした';

  @override
  String get aboutWhoCanSeeTitle => '誰が何を見られるか';

  @override
  String get aboutWhoCanSeeIntro =>
      'あなたの正確な位置情報を読めるのは、あなたが選んだ相手だけです。主な関係者がそれぞれ何を見られて、何を見られないのかを以下に示します。';

  @override
  String get aboutActorCirclesWho => '共有先のサークルのメンバー';

  @override
  String get aboutActorCirclesSees =>
      'あなたの正確な位置情報と、あなたが選んだ表示名。ただし共有しているサークルの中でだけで、ほかのサークルには見えません。';

  @override
  String get aboutActorRelaysWho => 'リレーの運用者';

  @override
  String get aboutActorRelaysSees =>
      'あなたのメッセージを中継するサーバーです。あなたのIPアドレス、あなたが公開に使う公開鍵（名前ではなくランダムなID）、通信のサイズとタイミング、そして誰かを検索したときにどのアカウントを探したかが見えます。あなたの位置情報、メッセージ、サークル名、サークルのメンバーを読むことは決してできません。';

  @override
  String get aboutActorMapWho => '地図プロバイダー（Stadia Maps）';

  @override
  String get aboutActorMapSees =>
      '地図を開いている間だけ、あなたのIPアドレスと表示中の範囲が見えます。正しい地図画像を送るためです。あなたのサークルや共有中の位置情報は決して見えません。Stadia はIPアドレスを匿名化し、あなたのデータを販売しません。';

  @override
  String get aboutActorDevelopersWho => 'Haven の開発者';

  @override
  String get aboutActorDevelopersSees =>
      '何も見えません。Haven はサーバーを一切運用せず、分析データも収集しません。開発者が見られるのはリレーの運用者と同じものだけで、しかもその開発者がたまたま運用しているリレーをあなたが使った場合に限られます。';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'とはいえ、あなたの活動が完全に見えないわけではありません。あなたが使うリレーや、ネットワークを監視している人は、接続のタイミングやメッセージのサイズから、あなたが活動していること、おおよその時間帯、頻度を知ることができます。';

  @override
  String get aboutScreenshotTitle => 'スクリーンショット保護';

  @override
  String get aboutScreenshotBody =>
      'Android では、Haven は位置情報の意図しない流出を防ぐため、アプリ全体でスクリーンショットと画面録画をブロックします。これはシステムレベルの保護（FLAG_SECURE）で、地図やメンバー一覧を含むアプリのすべての画面に適用されます。';

  @override
  String get aboutVpnTitle => 'VPN でさらにプライバシーを高める';

  @override
  String get aboutVpnBody =>
      'リレーや地図プロバイダーにはあなたのIPアドレスが見え、インターネットプロバイダーにはあなたがどのサーバーに接続したかが見えます。信頼できる VPN を使えば、これらの相手からIPアドレスを隠せます。おすすめは Mullvad です。VPN を使ってもサークルのメンバーに見える内容は変わらず、信頼の対象が VPN プロバイダーに移るだけです。';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License のもとで提供されています';

  @override
  String aboutFooterVersion(String version) {
    return 'バージョン $version';
  }

  @override
  String get commonClearAll => 'すべてクリア';

  @override
  String commonMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count人のメンバー',
    );
    return '$_temp0';
  }

  @override
  String get circlesTitle => 'サークル';

  @override
  String get circlesRefreshTooltip => 'サークルを更新';

  @override
  String get circlesRequiresIdentity => 'サークルを作成するには、まず識別情報の設定が必要です';

  @override
  String get circlesCreateCta => 'サークルを作成';

  @override
  String get circlesYourCircles => 'あなたのサークル';

  @override
  String get circlesEmptyTitle => 'まだサークルがありません';

  @override
  String get circlesEmptyMessage => 'サークルを作成して、信頼できる友人や家族と位置情報の共有を始めましょう。';

  @override
  String get circlesSheetEmptyMessage => 'サークルを作成して、信頼できる相手と位置情報の共有を始めましょう。';

  @override
  String get circlesLoadError => 'サークルを読み込めませんでした';

  @override
  String get circlesSelectToView => 'メンバーを表示するサークルを選択してください';

  @override
  String get circlesNoMembers => 'このサークルにはメンバーがいません';

  @override
  String get createCircleTitle => 'メンバーを追加';

  @override
  String createCircleSelectedCount(int count) {
    return '選択中（$count）';
  }

  @override
  String get createCircleEmptyTitle => 'サークルのメンバーを追加';

  @override
  String get createCircleEmptyMessage => 'IDで検索するか、QRコードをスキャンしてメンバーを追加します。';

  @override
  String get createCircleNoValidMembers => '招待できる有効なメンバーがいません';

  @override
  String get createCircleMemberAlreadyAdded => 'このメンバーはすでに追加されています';

  @override
  String get createCircleNoIdInQr => 'QRコードに有効なIDが見つかりませんでした';

  @override
  String get createCircleNoAccountFound => 'Haven のアカウントが見つかりませんでした';

  @override
  String get createCircleCouldNotVerify => 'メンバーを確認できませんでした';

  @override
  String get createCircleSomethingWentWrong => '問題が発生しました';

  @override
  String get nameCircleTitle => 'サークルに名前を付ける';

  @override
  String nameCircleMembersToInvite(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count人のメンバーを招待します',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'サークル名';

  @override
  String get nameCircleNameHint => '例: 家族、親しい友人';

  @override
  String get nameCircleNameEmptyError => 'サークル名を入力してください';

  @override
  String get nameCircleNameTooLongError => '名前は50文字以内で入力してください';

  @override
  String get nameCircleSharingInfo =>
      'このサークルのメンバーは、互いの位置情報と表示名を見られます。表示名は、設定 → 識別情報 で設定したものが使われます。このサークルは参加中のほかのサークルとは分離されているため、メンバーがあなたのほかのサークルやそのメンバーを見ることはできません。';

  @override
  String get nameCircleCreateCta => 'サークルを作成';

  @override
  String get nameCircleStageCreatingGroup => '安全なグループを作成しています...';

  @override
  String get nameCircleStageSendingInvites => '招待を送信しています...';

  @override
  String get nameCircleStageComplete => '完了しました！';

  @override
  String nameCircleProgressSemantics(String stage) {
    return '作成の進捗: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    return '$percentパーセント完了';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'サークル「$name」を作成しました！招待を$count件送信しました。',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError => '識別情報のエラーです。識別情報の設定をご確認ください。';

  @override
  String get nameCircleCreateError => 'サークルを作成できませんでした。もう一度お試しください。';

  @override
  String addMemberTitle(String circleName) {
    return '$circleName に追加';
  }

  @override
  String get addMemberInfo =>
      '新しいメンバーは、招待を承認すると、このサークルの暗号化された位置情報を見られるようになります。';

  @override
  String get addMemberAlreadyInCircle => 'すでにこのサークルのメンバーです';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '招待を送信',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '招待を送信しています...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$circleName に招待を送信しました',
    );
    return '$_temp0';
  }

  @override
  String addMemberPartialDelivery(int sent, int total) {
    return '招待を送信しました（$total件中$sent件）。残りは配信待ちです。';
  }

  @override
  String get addMemberError => 'メンバーを追加できませんでした。もう一度お試しください。';

  @override
  String get qrScannerTitle => 'QRコードをスキャン';

  @override
  String get qrScannerToggleFlash => 'フラッシュの切り替え';

  @override
  String get qrScannerSwitchCamera => 'カメラの切り替え';

  @override
  String get qrScannerInstruction => 'QRコードを枠の中に合わせてください';

  @override
  String get qrScannerScanning => 'スキャン中...';

  @override
  String get circleMemberInvitationPending => '招待保留中';

  @override
  String get circleMemberNoRecentLocation => '最近の位置情報はありません';

  @override
  String get circleMemberRemoveTooltip => 'サークルから削除';

  @override
  String get circleMemberAdmin => '管理者';

  @override
  String get circleMemberHintPending => '招待保留中';

  @override
  String get circleMemberHintNoLocation => '位置情報がありません';

  @override
  String get circleMemberHintMember => 'メンバー';

  @override
  String get circleMemberHintTapToCenter => 'タップすると地図をその位置に合わせます';

  @override
  String get pendingMemberRetryTooltip => '確認を再試行';

  @override
  String get pendingMemberRemoveTooltip => 'メンバーを削除';

  @override
  String get pendingMemberValidating => '確認中';

  @override
  String get pendingMemberValid => '有効';

  @override
  String get pendingMemberWarning => '警告';

  @override
  String get pendingMemberCheckingAvailability => '利用可能か確認しています...';

  @override
  String get pendingMemberReadyToInvite => '招待できます';

  @override
  String get memberSearchHint => 'メンバーIDを入力...';

  @override
  String get memberSearchPasteTooltip => 'クリップボードから貼り付け';

  @override
  String get memberSearchAddTooltip => 'メンバーを追加';

  @override
  String get memberSearchScanTooltip => 'QRコードをスキャン';

  @override
  String get memberSearchHelper => '連絡先に Haven のQRコードまたはIDを聞いてください';

  @override
  String get memberSearchNoValidId => '有効な Haven のIDが見つかりませんでした';

  @override
  String get memberSearchAlreadyAdded => 'このメンバーはすでに追加されています';

  @override
  String selectedMembersMore(int count) {
    return 'ほか$count人';
  }

  @override
  String get invitationStatusPending => '招待保留中';

  @override
  String get invitationStatusActive => 'アクティブ';

  @override
  String get invitationStatusDeclined => '辞退済み';

  @override
  String invitationStatusSemantics(String label) {
    return '招待の状態: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    return '$circleName への招待。招待者は $inviter、メンバー$count人';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return '暗号識別子 $inviter からの招待';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return '招待者: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count人のメンバー',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'たった今';

  @override
  String invitationCardDaysAgo(int count) {
    return '$count日前';
  }

  @override
  String invitationCardHoursAgo(int count) {
    return '$count時間前';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    return '$count分前';
  }

  @override
  String get invitationCardDecline => '辞退';

  @override
  String get invitationCardAccept => '承認';

  @override
  String get invitationAcceptedSnack => '招待を承認しました';

  @override
  String get invitationDeclinedSnack => '招待を辞退しました';

  @override
  String get invitationAcceptError => '招待を承認できませんでした。もう一度お試しください。';

  @override
  String get invitationDeclineError => '招待を辞退できませんでした。もう一度お試しください。';

  @override
  String get circleSelectorLabel => 'サークルの選択';

  @override
  String get circleSelectorPlaceholder => 'サークルを選択';

  @override
  String get circleSelectorNewCircle => '新しいサークル';

  @override
  String get circleSelectorLoadError => 'サークルを読み込めませんでした';

  @override
  String get circleSelectorExpandedAnnouncement => 'サークルの一覧を開きました';

  @override
  String get circleSelectorCollapsedAnnouncement => 'サークルの一覧を閉じました';

  @override
  String get circleDetailsButtonTooltip => 'サークルの詳細';

  @override
  String get circleDetailsTitle => 'サークルの詳細';

  @override
  String get circleDetailsRelaysHeading => 'このサークルのリレー';

  @override
  String get circleDetailsNoRelays => '（記録なし）';

  @override
  String get circleDetailsRelaysNote =>
      'これらのリレーはこのサークルの作成時に選ばれたもので、まだ編集できません。あなた個人のリレー設定とは独立しています。';

  @override
  String get circleDetailsAddMember => 'メンバーを追加';

  @override
  String get circleDetailsLeaveCircle => 'サークルを退出';

  @override
  String get leaveCircleDialogTitle => 'サークルを退出';

  @override
  String get leaveCircleDialogBody =>
      'このサークルを退出してもよろしいですか？メンバーの位置情報の更新を受け取れなくなります。この操作は元に戻せません。';

  @override
  String get leaveCircleConfirm => '退出';

  @override
  String get leaveCircleIdentityUnavailable => '識別情報を利用できません';

  @override
  String get leaveCircleSuccess => 'サークルを退出しました';

  @override
  String get leaveCircleError => 'サークルを退出できませんでした';

  @override
  String get circlesPanelCollapsedAnnouncement => 'サークルパネルを閉じました';

  @override
  String get circlesPanelExpandedAnnouncement => 'サークルパネルを開きました';

  @override
  String get circlesPanelSlightlyOpenAnnouncement => 'サークルパネルを少し開きました';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'サークルパネルを半分開きました';

  @override
  String get circleMemberAnnouncementSelf => 'あなた';

  @override
  String get circleMemberAnnouncementFallback => 'メンバー';

  @override
  String get invitationsRefreshTooltip => '招待を更新';

  @override
  String get invitationsLoadError => '招待を読み込めませんでした';

  @override
  String get invitationsEmptyTitle => '招待はありません';

  @override
  String get invitationsEmptyMessage => '誰かがあなたをサークルに招待すると、ここに表示されます。';

  @override
  String get invitationPillChecking => '受信トレイを確認しています…';

  @override
  String get invitationPillCheckingAnnouncement => '受信トレイを確認しています';

  @override
  String invitationPillNewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '新しい招待$count件',
    );
    return '$_temp0';
  }

  @override
  String get invitationPillUpToDate => 'すべて対応済み · 新着なし';

  @override
  String get invitationPillUpToDateAnnouncement => 'すべての受信トレイが応答しました。新着はありません';

  @override
  String invitationPillPartial(int responded, int total) {
    return '$total件中$responded件の受信トレイが応答しました';
  }

  @override
  String get invitationPillOffline => '受信トレイに接続できませんでした';

  @override
  String get invitationPillOfflineAnnouncement =>
      '受信トレイに接続できませんでした。もう一度お試しください';

  @override
  String get invitationPillNoInbox => '受信トレイが未設定です';

  @override
  String get invitationPillSetUp => '設定する';

  @override
  String get invitationPillDone => '完了';

  @override
  String get identityTitle => '識別情報';

  @override
  String get identityLoadError => '識別情報の読み込み中に問題が発生しました。もう一度お試しください。';

  @override
  String get identityMissingTitle => '識別情報がありません';

  @override
  String get identityMissingMessage =>
      '識別情報が失われています。Haven を引き続き使うには、新しく設定してください。';

  @override
  String get identitySetUpCta => '識別情報を設定';

  @override
  String get identityPublicKeyQrTitle => '公開鍵のQRコード';

  @override
  String get identityPublicKeyQrSubtitle => 'ほかの人があなたをサークルに招待する方法';

  @override
  String get identityAdvancedTitle => '詳細設定';

  @override
  String get identityAdvancedSubtitle => '公開鍵、秘密鍵、削除';

  @override
  String get identityVisibilityNote =>
      'あなたの写真と表示名を見られるのは、あなたが参加したサークルのメンバーだけです。招待は公開鍵またはQRコードを使って送られます。';

  @override
  String get identityAdvancedExportError => '秘密鍵を書き出せませんでした。もう一度お試しください。';

  @override
  String get identityAdvancedDeleteTitle => '識別情報を削除しますか？';

  @override
  String get identityAdvancedDeleteBody =>
      'これにより識別情報が完全に削除されます。後で復元したい場合は、秘密鍵をバックアップ済みであることを必ず確認してください。';

  @override
  String get identityAdvancedDeleteConfirm => '削除';

  @override
  String get identityAdvancedDeletedSnack => '識別情報を削除しました';

  @override
  String get identityAdvancedDeleteError => '識別情報を削除できませんでした。もう一度お試しください。';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$labelをクリップボードにコピーしました';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      '秘密鍵をコピーしました。警告: ほかのアプリがクリップボードを読み取れる場合があります。安全な場所に貼り付け、クリップボードを消去してください。';

  @override
  String get identityAdvancedMissingBody => '識別情報が設定されていません。';

  @override
  String get identityAdvancedPublicKeyLabel => '公開鍵';

  @override
  String get identityAdvancedPublicKeyHexLabel => '公開鍵（hex）';

  @override
  String get identityAdvancedCopyValue => '公開鍵';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => '公開鍵をコピー';

  @override
  String get identityAdvancedCopyHexTooltip => 'hex をコピー';

  @override
  String get identityAdvancedSecretKeyTitle => '秘密鍵';

  @override
  String get identityAdvancedSecretKeyWarning =>
      '秘密鍵があれば、あなたの識別情報に完全にアクセスできます。誰にも絶対に共有しないでください。';

  @override
  String get identityAdvancedRevealSecretKey => '秘密鍵を表示';

  @override
  String get identityAdvancedHideSecretKey => '秘密鍵を隠す';

  @override
  String get identityAdvancedCopySecretKeyTooltip => '秘密鍵をコピー';

  @override
  String get identityAdvancedDeleteIdentityCta => '識別情報を削除';

  @override
  String get qrCodeLoadError => '公開鍵の読み込み中に問題が発生しました。もう一度お試しください。';

  @override
  String get qrCodeYourPublicKeyLabel => 'あなたの公開鍵';

  @override
  String get qrCodeWhatIsThisTitle => 'これは何ですか？';

  @override
  String get qrCodeExplainerKeys =>
      'Haven は Nostr というオープンなネットワーク上で動いています。その背後に企業のアカウントや登録はありません。あなたの識別情報は、ただ1組の鍵です。あなただけが持つ秘密鍵と、そこから作られるこの公開鍵です。';

  @override
  String get qrCodeExplainerUsername =>
      'あなたの公開鍵は、共有しても安全なユーザー名のように働きます。人々はこのコードをスキャンするか、あなたの公開鍵を貼り付けて、あなたをサークルに招待します。公開鍵から、あなたの表示名、写真、位置情報が明らかになることはありません。これらは、あなたが参加したサークルのメンバーにだけ共有されます。';

  @override
  String get displayNameCardTitle => '表示名';

  @override
  String get displayNameCardLoadError => '表示名を読み込めませんでした。後でもう一度お試しください。';

  @override
  String get displayNameCardHint => '表示名を入力してください';

  @override
  String get displayNameCardSavedLabel => '表示名を保存済み';

  @override
  String get displayNameCardSaveLabel => '表示名を保存';

  @override
  String get displayNameCardSavingLabel => '表示名を保存しています';

  @override
  String get displayNameCardRetryLabel => '保存に失敗しました。再試行';

  @override
  String get displayNameCardSavedAnnouncement => '表示名を保存しました';

  @override
  String get displayNameCardSaveFailedAnnouncement => '保存に失敗しました。もう一度お試しください';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$labelをクリップボードにコピーしました';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => '表示中';

  @override
  String get keyDisplayStateHidden => '非表示';

  @override
  String get keyDisplayHideTooltip => '隠す';

  @override
  String get keyDisplayRevealTooltip => '表示';

  @override
  String get keyDisplayCopyTooltip => 'コピー';

  @override
  String get keyDisplayCompactCopied => '鍵をクリップボードにコピーしました';

  @override
  String get keyDisplayCompactTapToCopy => 'タップしてコピー';

  @override
  String get npubQrCopiedSnack => '公開鍵をクリップボードにコピーしました';

  @override
  String get npubQrCopyButton => '公開鍵をコピー';

  @override
  String get npubQrScanLabel => 'スキャンして追加';

  @override
  String get npubQrSemanticsLabel => 'あなたの公開識別情報のQRコード';

  @override
  String get photoHeaderRemoveTitle => 'プロフィール写真を削除しますか？';

  @override
  String get photoHeaderRemoveBody => 'これにより、あなたのサークルの全員から写真が削除されます。';

  @override
  String get photoHeaderEditPhoto => '写真を編集';

  @override
  String get photoHeaderRemove => '削除';

  @override
  String get photoHeaderViewPhotoSemantics => 'プロフィール写真を表示';

  @override
  String get photoHeaderAddPhotoSemantics => 'プロフィール写真を追加';

  @override
  String get photoHeaderChangePhotoSemantics => 'プロフィール写真を変更';

  @override
  String get avatarPickerPhotoUpdated =>
      '写真を更新しました — エンドツーエンドで暗号化され、サークルに共有されます。';

  @override
  String get avatarPickerPhotoRemoved => '写真を削除しました。';

  @override
  String get avatarPickerRemoveError => '写真を削除できませんでした。もう一度お試しください。';

  @override
  String get avatarPickerUpdateError => '写真を更新できませんでした。もう一度お試しください。';

  @override
  String get avatarPickerCropTitle => '写真を切り抜く';

  @override
  String get avatarPickerCropDone => '完了';

  @override
  String get avatarPickerCropCancel => 'キャンセル';

  @override
  String get avatarFullscreenClose => '閉じる';

  @override
  String get avatarFullscreenSemantics => 'プロフィール写真、全画面';

  @override
  String get avatarFullscreenLoadError => '写真を読み込めませんでした';

  @override
  String get mapInitializing => '初期化しています...';

  @override
  String get mapInitFailedTitle => '初期化に失敗しました';

  @override
  String get mapInitFailedMessage => '位置情報サービスを初期化できませんでした。';

  @override
  String get mapInitFailedRetry => '初期化に失敗しました。もう一度お試しください。';

  @override
  String get mapLocationOffMessage => '位置情報をオンにすると、地図上で自分とサークルのメンバーを確認できます。';

  @override
  String get mapGettingLocation => '位置情報を取得しています...';

  @override
  String get mapLoadingMap => '地図を読み込んでいます...';

  @override
  String get mapLocationOffTitle => '位置情報がオフです';

  @override
  String get mapLocationErrorTitle => '位置情報のエラー';

  @override
  String get mapLocationUnavailable => '位置情報を一時的に取得できません';

  @override
  String get mapThisLocation => 'この場所';

  @override
  String get mapMemberFallbackName => 'メンバー';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '$label を Apple Maps で開きますか？';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Apple Maps に送られるのは地図上の座標だけで、名前や識別情報は送られません。';

  @override
  String get mapOpenInAppleMapsConfirm => 'Apple Maps で開く';

  @override
  String get mapOpenMapsError => 'Maps を開けませんでした';

  @override
  String get mapControlsZoomIn => '拡大';

  @override
  String get mapControlsZoomOut => '縮小';

  @override
  String get mapControlsRecenter => '中央に戻す';

  @override
  String get mapControlsRecenterFab => '自分の位置を中央に表示';

  @override
  String get mapAttributionCreditsButton => '地図のクレジットとライセンス';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'あなたの位置マーカー$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    return '。精度: $metersメートル';
  }

  @override
  String memberMarkerMinutesShort(int count) {
    return '${count}m';
  }

  @override
  String memberMarkerHoursShort(int count) {
    return '${count}h';
  }

  @override
  String memberMarkerDaysShort(int count) {
    return '${count}d';
  }

  @override
  String memberMarkerMinutesAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count分前',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerHoursAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count時間前',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerDaysAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count日前',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return '$name のメンバーマーカー';
  }

  @override
  String get memberMarkerGenericSemantics => 'メンバーマーカー';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base、最終確認 $age';
  }

  @override
  String get commonAdd => '追加';

  @override
  String get addRelaySheetTitleInbox => '受信トレイのリレーを追加';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage リレーを追加';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'クリップボードから貼り付け';

  @override
  String get addRelaySheetErrorEmpty => 'リレーのアドレスを入力してください。';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'このリレーへの通信が暗号化されるよう、wss:// を使用してください。';

  @override
  String get addRelaySheetErrorHasCredentials => 'リレーのURLに認証情報を含めることはできません。';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'wss://relay.example.com のようなリレーのアドレスを入力してください。';

  @override
  String get avatarSemanticsLabel => 'ユーザーのアバター';

  @override
  String avatarSemanticsFor(String initials) {
    return '$initials さんの';
  }

  @override
  String get avatarSemanticsOnline => 'オンライン';

  @override
  String get avatarSemanticsOffline => 'オフライン';
}
