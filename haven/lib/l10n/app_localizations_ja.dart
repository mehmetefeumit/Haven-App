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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '保留中の招待$countString件',
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
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'ステップ $currentString / $totalString';
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
      'Haven には中央サーバーがありません。暗号化されたメッセージは、「リレー」と呼ばれる独立したサーバーを経由して届き、どのリレーを使うかはあなたが選びます。特定の企業や政府が単独でこのネットワークを止めることはできません。';

  @override
  String get onboardingValueProp3Title => 'アカウントは不要';

  @override
  String get onboardingValueProp3Body =>
      'メールアドレスも電話番号も、登録も不要です。Haven が作る識別情報の秘密鍵は、あなたの端末から外に出ることがありません。だから、誰かが引き渡せるアカウントそのものが存在しません。';

  @override
  String get onboardingValueProp1Summary => '端末上で暗号化。あなたが選んだサークルだけが読めます。';

  @override
  String get onboardingValueProp2Summary => '中央サーバーなし。あなたが選ぶリレーネットワークで動作します。';

  @override
  String get onboardingValueProp3Summary =>
      'メール、電話番号、登録は不要。秘密鍵が端末から出ることはありません。';

  @override
  String get onboardingCreateIdentityTitle => '識別情報を作成';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven はこの端末の中であなたの鍵を作成します。秘密鍵がこの端末を離れることはありません。';

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
  String get onboardingDisplayNameHint => '例: アレックス';

  @override
  String get onboardingDisplayNameError => 'その名前を保存できませんでした。もう一度お試しください。';

  @override
  String get onboardingAddPhotoOptional => '写真を追加（任意）';

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
  String get relaySettingsInboxSubtitle => '招待があなたに届く場所（kind 10050）';

  @override
  String get relaySettingsKeyPackageTitle => 'KeyPackage リレー';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'あなたを招待するために必要な鍵を、ほかの人が見つける場所（kind 10002）';

  @override
  String get relaySettingsProfileTitle => 'プロフィールリレー';

  @override
  String get relaySettingsProfileSubtitle =>
      'あなたの公開プロフィールを取得・公開する場所。これらのリレーはあなたのほかのリレーとは分けられており、プロフィールリレーのリスト自体が公開されることはありません（kind 0）';

  @override
  String get relaySettingsProfileUnderflowTitle => 'プロフィールの取得を一時停止中';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'プロフィールリレーが少なくなりすぎたため、メンバーの名前と写真が更新されなくなります。';

  @override
  String get relaySettingsProfileUnderflowRestoreButton => 'デフォルトのプロフィールリレーを復元';

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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '現在の$countString件のリレーが Haven のデフォルトに置き換えられます。この操作は元に戻せません。',
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
  String get relaySettingsProfileContaminationTooltip => 'Haven のほかの通信も中継します';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return '警告: $url は Haven でのあなたのほかの通信も中継しているため、このリレーがあなたのプロフィールとその通信を結び付ける可能性があります';
  }

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
      'Haven は、アプリを開いている間は常に、あなたの位置情報をサークルに共有します。これをオンにすると、Haven がバックグラウンドにある間もサークルのメンバーは位置情報を見続けられます。システムが Haven を終了させた場合は共有が停止します。バックグラウンドでの起動時に行われるのはサークルの位置情報の受信だけで、あなたの位置情報が送信されることはありません。Android では、Haven をスワイプして最近使ったアプリから消しても共有は動き続け、端末を再起動したあとには共有が自動的にまた始まります。iPhone では、あなたが Haven を開くまで共有は停止したままです。';

  @override
  String get locationSettingsToggleTitle => 'バックグラウンドで共有';

  @override
  String get locationSettingsToggleSubtitle => 'Haven がバックグラウンドにある間も共有を続けます';

  @override
  String get locationSettingsIosLimitedNote =>
      '現在の権限のままでも、バックグラウンドでの共有は継続されます。設定で Haven の位置情報を「常に許可」にすると、iOS がアプリを終了した後も、Haven がサークルの位置情報に追いつけるようになります。あなた自身の位置情報の共有は、Haven を開き直したときに再開されます。';

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
      'バックグラウンド共有がオンの間、Haven は位置情報の取得を継続するため、iOS のステータスバーに青い表示が出ます。さらに「常に許可」を選ぶと、iOS がアプリを終了した後も、Haven がサークルの更新に追いつけるようになります。';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License のもとで提供されています';

  @override
  String aboutFooterVersion(String version) {
    return 'バージョン $version';
  }

  @override
  String get privacyTitle => 'プライバシー';

  @override
  String get privacySubtitle => 'Haven がどう動くか、ほかの人に何が見えるか';

  @override
  String get privacyHubSummary =>
      'Haven は、あなたが選んだ少人数のグループ、つまりサークルにだけ位置情報を共有し、端末を離れる前にこの端末上で暗号化します。登録の手続きはなく、Haven のサーバーもありません。あなたが設定した表示名と写真は公開されます。ほかの人があなたを招待するために必要な鍵と、どのリレーを使うかを示すリストも同じく公開されます。以下のページでは、その点も含め、すべてをやさしい言葉で説明します。';

  @override
  String get privacyGroupBasicsHeading => '基本';

  @override
  String get privacyMeansForYouLabel => 'あなたにとっての意味';

  @override
  String get privacyMoreDetailLabel => 'もっと詳しく';

  @override
  String get privacyMoreDetailExpandHint => '技術的な詳細を表示';

  @override
  String get privacyMoreDetailCollapseHint => '技術的な詳細を隠す';

  @override
  String get privacyMoreDetailExpandedAnnouncement => '技術的な詳細を表示しました';

  @override
  String get privacyMoreDetailCollapsedAnnouncement => '技術的な詳細を隠しました';

  @override
  String get privacyWhatHavenIsTitle => 'アカウントがない理由と、Haven の仕組み';

  @override
  String get privacyWhatHavenIsSubtitle => '登録も、企業のサーバーもありません';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven は、あなたが選んだ少人数のグループ、つまりサークルに位置情報を共有します。その背後にアカウントはありません。メールアドレスや電話番号、パスワードを渡すことは一切ありません。';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven 自身もサーバーを運用していません。暗号化された位置情報の更新は、ほかの人たちが運用する独立したサーバー、いわゆる「リレー」を経由します。Haven の開発者があなたの位置情報を見ることはできず、アプリに追跡の仕組みも入れていません。開発者に分かるのは、地図が全体でどれだけ使われたかという合計だけです。地図のタイルは全員で共有する1つのキーで取得されるため、誰が取得したのかは分かりません。';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'リレーの運営者が、あなたの位置情報を引き渡すよう強制されることはありません。それを運ぶサーバーには、中身が読めないからです。その代償として、あなたの識別情報を復元してくれる人もいません。また、すでに公開したものは公開されたまま残ります。何をバックアップすればよいかは「2つの鍵」をご覧ください。';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'アプリには分析、クラッシュレポート、広告のコードが一切含まれていません。Haven はオープンソースなので、これは信頼に頼るのではなく、実際に確認できます。';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven にはプッシュ通知もありません。これは意図的です。通知サービスを使うとなると、あなたのサークルの誰かに届けるものがあるたびに、その事実をサービス側に伝えなければなりません。それはリレー以上に、あなたの生活習慣を明らかにしてしまいます。';

  @override
  String get privacyYourKeysTitle => '2つの鍵: ひとつは秘密、ひとつは共有用';

  @override
  String get privacyYourKeysSubtitle => 'あなたを示すものと、バックアップすべきもの';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'ユーザー名とパスワードの代わりに、あなたは1組の鍵を持ちます。秘密鍵は、あなたがあなたであることを証明します。公開鍵は、ほかの人があなたを見つけて招待するために使うものです。';

  @override
  String get privacyYourKeysSecretStaysHere =>
      '秘密鍵はこの端末の中だけに、OS が保護する領域に保管されます。Haven がそれをどこかに送ることはありません: どのサーバーにも、私たちにも送りません。';

  @override
  String get privacyYourKeysPublicIsSafe =>
      '公開鍵は人に渡しても安全です。どこにでも掲載できるユーザー名のようなものです。共有しても、あなたの居場所が明らかになることはありません。';

  @override
  String get privacyYourKeysMeansForYou =>
      'この識別情報を持ち続けたい場合は、バックアップしてください。設定 → 識別情報 → 詳細設定 と進み、「秘密鍵を表示」をタップして、パスワードマネージャーなど安全な場所に保存します。そのバックアップがないまま端末を失うと、その識別情報は永久に失われます。';

  @override
  String get privacyYourKeysNeverShareSecret =>
      '秘密鍵を手に入れた人は、あなたになりすませます。あなたとしてサークルに参加したり、あなたの名前で公開したりできてしまいます。ほかのアプリやメッセージ、ウェブサイトに貼り付けることは絶対にしないでください。';

  @override
  String get privacyYourKeysDetailFormats =>
      'どちらの鍵も secp256k1 で、標準的な Nostr の形式で表示されます: 公開鍵は npub1…、秘密鍵は nsec1… です。署名はアプリの中で行われ、秘密の値は、それを直接扱う部分から使用後ただちに消去されます。';

  @override
  String get privacyYourKeysDetailSeparation =>
      'サークルのメッセージを暗号化する鍵は、この識別情報の鍵とは別のもので、アプリだけが保持します。この分離は意図的なものです。あなたを名指しする鍵は、あなたが送った内容を開ける鍵ではありません。';

  @override
  String get privacyPublicProfileTitle => 'あなたの名前と写真は公開されます';

  @override
  String get privacyPublicProfileSubtitle => 'サークルのメンバーだけでなく、誰からも見えます';

  @override
  String get privacyPublicProfileIsPublic =>
      '設定した表示名と写真は、Haven が動作している開かれた公開ネットワーク、Nostr に公開されます。あなたのサークルのメンバーだけでなく、誰でも調べることができます。';

  @override
  String get privacyPublicProfileOnSave =>
      'あなたの名前と写真は、保存した時点で公開されます。非公開のままにする設定はなく、名前をサークルの中だけで共有する方法もありません。';

  @override
  String get privacyPublicProfilePseudonym =>
      '新しくインストールすると、「Quiet Wanderer」のような、あなたについて何も語らない架空の名前から始まります。そのまま使っても、好きな名前に変えてもかまいません。';

  @override
  String get privacyPublicProfileMeansForYou =>
      '公開しても差し支えない名前と写真を選んでください。誰だと気づかれたくない場合は、最初に与えられた架空の名前をそのまま使い、写真は設定しないでおきましょう。';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'あとで写真を削除しても、サーバー上のコピーが消えるわけではありません。Haven はあなたのプロフィールを空のものに置き換えるだけです。画像ファイルはそれを預かっている場所に残り、すでにダウンロードされたコピーも世の中に残ります。公開したものは元に戻せないと考えてください。';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'プロフィールは、あなたの識別情報の鍵で署名された Nostr の「kind 0」イベントです。写真は、公開の画像ホストである blossom.primal.net にアップロードされます。そのホストには、画像、あなたの公開鍵、あなたのネットワークアドレスが見えます。Haven では、まだ別のホストを選ぶことはできません。';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'アップロードの前に、Haven は画像を再エンコードし、カメラが埋め込む隠れたデータを取り除きます。写真を撮った GPS の位置も、そこに含まれます。これは重要な点です。そうでなければ、旅行先のスナップ写真が自宅の座標を持ち歩くことになりかねません。';

  @override
  String get privacyGroupHowLocationTravelsHeading => '位置情報がたどる経路';

  @override
  String get privacyRelaysTitle => 'リレー: メッセージを受け渡すサーバー';

  @override
  String get privacyRelaysSubtitle => 'あなたの更新が誰のコンピューターを通るのか';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven には自前のサーバーがありません。そのため、あなたの更新はほかの人たちのサーバーを経由します。これらは、誰でも運用できる小さな独立したサーバーで、「リレー」と呼ばれます。リレーは暗号化されたメッセージを短い時間だけ預かり、あなたのサークルが求めたときに次へ渡します。';

  @override
  String get privacyRelaysWhyMany =>
      'Haven は複数のリレーを使うので、どれか1つがあなたを遮断することはできません。1つがオフラインになっても、ほかは動き続けます。招待が届くリレーはあなたが選べますが、サークルが使うリレーは、そのサークルの作成時に決まります。';

  @override
  String get privacyRelaysYourLists =>
      'Haven はあなたのために3つのリストを保持します。受信トレイのリレーは、招待があなたに届く場所です。KeyPackage リレーは、あなたを招待するために必要な鍵を、ほかの人が取得する場所です。この2つのリストは、ほかの人が見つけられるように Haven が公開します。プロフィールリレーはこれらとは異なり、あなたの名前と写真を取得・公開する場所ですが、リスト自体は端末内にとどまり、公開されることはありません。そのため、あなたの位置情報の更新や招待だけを扱うリレーには、あなたがプロフィールにどのリレーを使っているかを示す公開リストはありません。さらに、各サークルも独自のリストを持っており、そのサークルの暗号化された更新はそこを通ります。';

  @override
  String get privacyRelaysMeansForYou =>
      'リレーがあなたの位置情報を見ることはありません。端末を離れる前に暗号化されているからです。一方で、ほかの人があなたに連絡するために公開が必要なものは見えています: ほかの人があなたを招待するために必要な鍵と、どのリレーを使うかを示すリストです。あなたの名前と写真も公開されますが、こちらは別のリレーの集まりに送られます。Haven には最初から使えるリレーが設定されているので、あなたが変更しなければならないものはありません。';

  @override
  String get privacyRelaysDetailIndexers =>
      'あなた自身のリストとは別に、Haven はあなたが選んでいない公開サーバーを、決まった2つのグループとして使います: ほかの人の名前と写真を調べるための8台と、その人を招待するために必要な鍵を調べるための6台です。この2つのグループに重複するサーバーはありません。プロフィール用のグループには自分のサーバーを追加できますが、この8台を取り除くことはできません。自分用に選んだリレーがすべて非公開であっても、Haven はこの両方に接続します。そして、そのどれもがあなたのネットワークアドレスを見ることになります。';

  @override
  String get privacyRelaysDetailProfileLookups =>
      '名前と写真については、Haven は一度に1人分だけを問い合わせます。人ごとに問い合わせ先のサーバーが端末上で1台決まり、そのサーバーにその人の情報がなければ、Haven はもう1台だけ試します。そのため、誰かを調べたときにその人のことが伝わるのは、8台のうち多くても2台までで、8台全体に伝わることはありません。Haven がこの割り当てを自分から組み替えることはありませんが、サーバーの顔ぶれが変われば割り当ても変わります。この割り当てによって、問い合わせは1台に集中せず分散します。ただし、ある人に割り当てられたサーバーには、あなたの端末がその人について繰り返し問い合わせているという記録が、長期にわたって積み上がります。また、相手が数人だけのときは、その多くが同じサーバーに割り当てられることもあります。あなたが自分の名前や写真を保存すると、それは実際に使っているプロフィールリレーすべてに送られます。つまり、8台のうち Haven が除外したものを除き、あなたが追加したものを加えた分です。そのため、そのどれもがあなたの公開鍵を知ることになります。';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'あなたの KeyPackage リレーのリストは、あなたの識別情報の鍵で署名され、すでにそのリストに入っているリレーへ公開されます。そこに非公開のリレーを追加すると、そのアドレスは公開され、あなたと結びつきます。このリストに載せたリレーを非公開のままにしておく方法はありません。';

  @override
  String get privacyEncryptionTitle => '暗号化の仕組み';

  @override
  String get privacyEncryptionSubtitle => 'サークルにつき鍵は1つ。人が出入りしたときに変わること';

  @override
  String get privacyEncryptionPerCircle =>
      'あなたの位置情報は、MLS というオープンな標準を使って、この端末を離れる前に端末内で暗号化されます。各サークルは、それぞれ固有の鍵を持つ独立した暗号化グループです。サークルの外にいる人が、その中で送られた内容を読むことはできません: リレーも、Haven も、あなたが参加しているほかのサークルも読めません。';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      '誰かが参加すると、そのサークルは新しい鍵に切り替わります。参加したあとに送られたものは読めますが、それ以前のものは読めません。Haven が新しいメンバーに過去の位置情報を送ることはありません。';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      '誰かがサークルを抜けると、そのサークルはまた別の新しい鍵に切り替わります。その人が新しいものを読めなくなるのは、サークルの残りのメンバーが追いついた時点です。通常は数分のうちですが、そのときオフラインだった人がいると、もっと時間がかかります。';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'サークルを抜けても、メンバーがすでに保存したものを取り戻すことはできません。Haven が鍵を変えるのは、誰かが参加するか抜けたときだけで、一定時間ごとに変わることはありません。そのため、1つの鍵が何週間分ものメッセージをカバーすることがあり、その間にメンバーが保存したものは、その人にとって読める状態のまま残ります。ただし、その人が抜けたあとに送られたものは開けません。';

  @override
  String get privacyEncryptionMeansForYou =>
      '暗号化は、サークルの外にいるすべての人からあなたを守ります。かつて中にいた人から守ることはできません。特定の相手との共有をやめたい場合は、その人と共有しているサークルを退出し、その人を入れずに新しいサークルを作ってください。';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS（Messaging Layer Security）は、ほかの安全なメッセージアプリでも使われている IETF の標準です。Haven は Marmot プロトコルを通じて Nostr ネットワークに接続します。Marmot は、MLS のグループがリレー上をどう流れるかを定めた仕様です。各サークルが署名に使う鍵は、公開されている Nostr の識別情報の鍵とは別のものです。';

  @override
  String get privacyEncryptionDetailEpochs =>
      '鍵が有効な各期間は「エポック」と呼ばれ、サークルが新しいエポックに移るのは、メンバーの構成が変わったときだけです。この端末は、現在のエポックと直近のいくつかのエポックの鍵、つまり届く途中のメッセージを開けるだけの分を保持し、残りは破棄します。数か月間メンバーの構成が変わっていないサークルは、今も最初のエポックのままです。';

  @override
  String get privacyWhatOthersSeeTitle => 'メンバーに見えるもの、リレーに見えるもの';

  @override
  String get privacyWhatOthersSeeSubtitle => '共有する相手と、その間にあるサーバー';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'サークルにいる人たち';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'サークルのメンバー全員に、地図上のあなたの正確な位置が見えます。おおまかな範囲ではありません。一部のメンバーにはぼかした位置を、ほかのメンバーには正確な位置を共有する、といった設定はありません。';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Haven を開いていて、どこかのサークルに参加している間は、数分ごとに自動であなたの位置が送信されます。一時停止するボタンはありません: 「位置情報」ページのスイッチが切り替えるのは、Haven がバックグラウンドにある間も共有を続けるかどうかだけです。システムが Haven を終了させた場合は共有が停止します。Android では、Haven をスワイプして最近使ったアプリから消しても共有は動き続け、端末を再起動したあとには共有が自動的にまた始まります。iPhone では、あなたが Haven を開くまで共有は停止したままです。あるサークルとの共有をやめるには、そのサークルを開いて「サークルを退出」を選んでください。';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'サークルに参加すると、あなたの公開鍵もメンバー全員に見えます。メンバーはそれを使って、あなたの公開プロフィールや、その鍵でこれまでに公開したすべてのものを調べられます。';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'あなたの端末は、各メンバーのプロフィール写真を、そのメンバーが選んだサーバーから取得します。これは、あなたが何もタップしなくても自動的に起こります。すると、そのサーバーにはあなたのネットワークアドレスが見え、そこからおおよその居場所が地図上で分かってしまいます。これを隠せるのは VPN だけで、ほかに防ぐ手立てはありません。';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'リレーの運営者';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'あなたの更新が経由する独立したサーバー、つまりリレーは、あなたの位置情報、メッセージ、サークルの名前、メンバーの一覧を読めません。位置情報の更新には、あなたの公開鍵ではなく、その都度新しい使い捨ての送信アドレスが使われます。ただし、あなたのプロフィール、招待、リレーのリストには公開鍵がそのまま入ります。そのため、その両方を扱うリレーは、中身を一切読まなくても、あなたがどこかのサークルに参加していることを推測できる場合があります。';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      '一方で、あなたのネットワークアドレス、オンラインになっている時間帯、通信の大きさと頻度は見えています。各サークルにはランダムなタグが付いています。リレーはそのタグで1つのサークルのメッセージをまとめ、そこに何人いるかを推測できます。ただし、それが誰なのかは分かりません。';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'サークルに参加するのは、自宅の住所を教えてもよい相手とだけにしてください。リレーや外部の相手に対しては暗号化が守ってくれますし、VPN を使えば端末が接続してくるアドレスを隠せます。しかし、スクリーンショットを撮るメンバーからは、何もあなたを守ってくれません。';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'サークルのタグは、そのサークルが存在する間ずっと同じです。そのため、リレーはそのサークルのメッセージをいつまでも結びつけられます。プロトコル自体はサークルが新しいタグに移ることを認めていますが、Haven は現在それを行っていません。また、タグを移しても、リレーがすでに結びつけた分が取り消されるわけではありません。';

  @override
  String get commonLearnMore => '詳しく見る';

  @override
  String get relaySettingsBackendCaption =>
      'Haven には自前のサーバーがありません。暗号化されたあなたの更新は、「リレー」と呼ばれる独立したサーバーを経由します。リレーが、あなたの位置情報やメッセージを読むことはできません。';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'これは端末によって異なります。Android では、Haven がアプリ全体でスクリーンショットと画面録画をブロックします。iPhone ではそれができません: Haven はアプリスイッチャーのプレビューをぼかしますが、メンバーが画面に映っているものを撮影することは依然として可能です。';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven はリレーに対し、位置情報のメッセージを約4分後に破棄するよう求めます。これはあくまで要望であり、リレーはそれより長く保持することもできます。この有効期限が付くのは位置情報の更新だけなので、有効期限が付いていないメッセージは、位置情報の更新ではなくメンバーの構成の変更だと一目で分かります。招待には有効期限が一切なく、受信トレイのリレーにいつまでも残る可能性があります。';

  @override
  String get privacyWhatOthersSeeDetailOnDevice =>
      '各メンバーの端末は、あなたから受け取った最後の位置情報を1日後には表示しなくなり、そのメンバーが次に Haven を開いたときに削除します。これは、メンバー自身が保存したりスクリーンショットを撮ったりしたものとは別の話で、そちらに Haven は関与できません。';

  @override
  String get privacyWhatOthersSeeDetailOneConnection =>
      'Haven は各リレーへの接続を1本だけ開き、そのリレーでのやり取りはすべてその接続で行います。あなたの招待とあるサークルのメッセージを同じリレーが扱っている場合、その1本の接続が、あなた自身の公開鍵宛ての招待と、そのサークルのタグが付いたメッセージを、同時に要求します。これによって、リレーは両者を結びつけられます。新規インストール時は、どちらにも同じリレーが使われます。';

  @override
  String get privacyGroupTheLimitsHeading => '限界';

  @override
  String get privacyInferenceTitle => 'それでも推測できてしまうこと';

  @override
  String get privacyInferenceSubtitle => '暗号化では隠せない痕跡';

  @override
  String get privacyInferenceWhatIsMetadata =>
      '暗号化は、あなたが送る内容を隠します。しかし、あなたが何かを送ったという事実は隠せません。そこに残る痕跡は「メタデータ」と呼ばれます: メッセージがいつ送られたか、どのくらいの大きさだったか、どのサーバーに接続していたか、といった情報です。中身が見えなくなっても、これは見えたままです。';

  @override
  String get privacyInferenceActivityPattern =>
      'そのパターンから、あなたが使うリレーは、あなたがいつ、どのくらいの頻度で活動しているかをおおまかに知ることができます。Haven が画面に表示されている間、そして iPhone ではバックグラウンド共有によってアプリが動き続けている間は、約100メートル移動するたびに追加の更新も送られます。この追加の更新が送られるのは、多くても1分に1回までです。何時間分もの記録があれば、リレーは、あなたが移動していたのか、同じ場所にとどまっていたのかを見分けられます。ただし、そのパターンから、あなたがどこにいるかが分かることは決してありません。';

  @override
  String get privacyInferencePresence =>
      'Haven が動いている間は、あなたのリレーへの接続を開いたままにします。そのためリレーには、あなたがオンラインであること、そしてあなたがどのサークルのタグを追っているかが分かります。サークルの名前や、そこに誰がいるかが分かることはありません。これは、更新が数分ではなく数秒で届くことの代償です。';

  @override
  String get privacyInferenceIpHeading => 'あなたのネットワークアドレス';

  @override
  String get privacyInferenceIpAddress =>
      'Haven が通信するすべてのサーバーには、あなたの端末が接続してくるアドレス、つまり IP アドレスが見えます: あなたのリレー、地図プロバイダー、そしてメンバーのプロフィール写真を預かっているサーバーです。インターネットプロバイダーには、そのうちどのサーバーにいつ接続したかが見えます。Haven だけでは、そのどちらも隠せません。';

  @override
  String get privacyInferenceMapTilesHeading => '地図そのもの';

  @override
  String get privacyInferenceMapTiles =>
      '地図を描くには、画面に映っている四角い画像を地図プロバイダーに求める必要があります。そのため、プロバイダーにはあなたがどのあたりを見ているかがおおまかに分かります。Haven はさらに、あなたが見ることのできるメンバーそれぞれの周囲についても、あなたがそこへ地図を動かす前に、狭い範囲をあらかじめ取得しています。地図をすぐ表示するためですが、その結果プロバイダーには、あなたが見ている場所だけでなく、サークルのメンバーがいるおおよその場所まで分かることになります。これらの画像は、あなたの端末上の暗号化されたキャッシュに最長7日間保存され、識別情報を削除した場合はまとめて消去されます。';

  @override
  String get privacyInferenceVpnHeading => 'VPN を使うかどうか';

  @override
  String get privacyInferenceVpnHelps =>
      'VPN は、あなたのアドレスを VPN 自身のアドレスに置き換えます。そのため、リレーやほかのサーバーには、あなたがどこから接続しているかが見えなくなります。どのサーバーに接続したかを、インターネットプロバイダーから隠すこともできます。おすすめは Mullvad です。';

  @override
  String get privacyInferenceVpnLimits =>
      '万能ではありません。VPN を使っても、サークルのメンバーに見える内容は何も変わりません。やり取りしているリレーに対して、通信のタイミングやサイズを隠すこともできません。また、誰も信頼しなくてよくなるわけではなく、信頼の対象が VPN プロバイダーに移るだけです。';

  @override
  String get privacyInferenceMeansForYou =>
      'リレーやインターネットプロバイダー、地図のサーバーに地図上の居場所を突き止められることが心配ですか？その場合、VPN は追加できるもののなかで最も役に立ちます。心配なのがサークルの中の人たちであれば、VPN はまったく役に立ちません。';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven は更新の間隔をわざとばらつかせているので、短い時間の記録ではきれいな規則性が見えません。それでも、何時間も平均すれば、もとの頻度は推定できます。メッセージのサイズも一定にそろえてはおらず、位置情報の更新は狭いサイズの範囲に収まるため、位置情報の更新だと見分けられます。';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'ここでどのような設計を選んでも解決できないことが2つあります: 多くのリレーを同時に監視できる相手と、ほかの人に乗っ取られたあなた自身の端末です。';

  @override
  String get commonClearAll => 'すべてクリア';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString人のメンバー',
    );
    return '$_temp0';
  }

  @override
  String commonNumber(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '選択中（$countString）';
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
  String get createCircleNoAccountFound => 'この ID の Haven アカウントが見つかりませんでした';

  @override
  String get createCircleCouldNotVerify => 'メンバーを確認できませんでした';

  @override
  String get createCircleSomethingWentWrong => '問題が発生しました';

  @override
  String get nameCircleTitle => 'サークルに名前を付ける';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString人のメンバーを招待します',
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
      'このサークルのメンバーは、互いの位置情報と、互いの公開の名前と写真を見られます。あなたの名前と写真は Nostr ネットワーク上で公開されており、このサークルの中だけのものではありません。このサークルは参加中のほかのサークルとは分離されているため、メンバーがあなたのほかのサークルやそのメンバーを見ることはできません。';

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
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentStringパーセント完了';
  }

  @override
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'サークル「$name」を作成しました。招待を送信しました（$totalString件中$sentString件）。残りは配信待ちです。';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'サークル「$name」を作成しました！招待を$countString件送信しました。',
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
      '相手が承認すると、その時点から先の全員の位置情報が見えるようになります。参加前に送られたものが見えることはありません。また、このサークルにすでにいる全員の公開鍵も見えるようになります。';

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
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '招待を送信しました（$totalString件中$sentString件）。残りは配信待ちです。';
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
  String circleMemberRemoveDialogTitle(String name) {
    return '$name をサークルから削除しますか？';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'サークルの残りのメンバーが追いついた時点で、その人はこのサークルの新しいものを読めなくなります。通常は数分のうちですが、そのときオフラインだった人がいると、もっと時間がかかります。すでに受け取ったものは、相手の端末に残ります。元に戻すには、あらためて招待する必要があります。';

  @override
  String get circleMemberRemoveConfirm => '削除';

  @override
  String circleMemberRemoveInProgress(String name) {
    return '$name を削除しています…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name をサークルから削除しました';
  }

  @override
  String circleMemberRemoveError(String name) {
    return '$name を削除できませんでした。変更はありません。接続を確認して、もう一度お試しください。';
  }

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
  String get pendingMemberRemoveTooltip => 'リストから削除';

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
  String get pendingMemberNeedsUpdate => 'Haven のアップデートが必要です';

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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'ほか$countString人';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$circleName への招待。招待者は $inviter、メンバー$countString人';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString人のメンバー',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'たった今';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString日前';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString時間前';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString分前';
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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members・エポック$epochString';
  }

  @override
  String get circleDetailsRelaysHeading => 'このサークルのリレー';

  @override
  String get circleDetailsNoRelays => '（記録なし）';

  @override
  String get circleDetailsRelaysNote =>
      'これらのリレーは、招待されたメンバーが公開したリストから取り込まれました。公開したメンバーがいなければ、あなたの受信トレイのリレーか Haven が選んだリレーが使われました。まだ変更できず、あとからリレーのリストを編集しても変わりません。';

  @override
  String get circleDetailsAddMember => 'メンバーを追加';

  @override
  String get circleDetailsLeaveCircle => 'サークルを退出';

  @override
  String get leaveCircleDialogTitle => 'サークルを退出';

  @override
  String get leaveCircleDialogBody =>
      'このサークルを退出しますか？メンバーへの位置情報の送信は止まり、メンバーの位置情報も見えなくなります。最後に送った位置は、最大で1日ほど相手の端末に残ります。この操作は元に戻せません: 再び参加するには、新しい招待が必要になります。';

  @override
  String get leaveCircleConfirm => '退出';

  @override
  String get leaveCircleIdentityUnavailable => '識別情報を利用できません';

  @override
  String get leaveCircleSuccess => 'サークルを退出しました';

  @override
  String get leaveCircleError => 'サークルを退出できませんでした';

  @override
  String get circleBlockedBannerTitle => 'このサークルは更新できません';

  @override
  String get circleBlockedBannerBody =>
      'このサークルの暗号化で問題が発生したため、Haven はこのサークルで更新を送受信できなくなりました。以下で最後に確認できた情報は引き続き見られますが、サークルを退出することもできます。';

  @override
  String get legacyCircleBannerTitle => 'このサークルは再作成が必要です';

  @override
  String get legacyCircleBannerBody =>
      'Haven の暗号化エンジンがアップグレードされたため、このサークルは使用できなくなりました。同じメンバーと引き続き位置情報を共有するには、サークルを再作成してください。メンバーを改めて招待する必要があります。';

  @override
  String get legacyCircleRecreateCta => 'サークルを再作成';

  @override
  String get legacyCircleRemoveCta => '削除';

  @override
  String get legacyCircleRemoveDialogTitle => 'サークルを削除しますか？';

  @override
  String get legacyCircleRemoveDialogBody =>
      'このサークルはもう使用できないため、リストから削除されます。これは、代わりに作成する新しいサークルには影響しません。';

  @override
  String get legacyCircleRemoveConfirm => '削除';

  @override
  String get legacyCutoverExplainerTitle => 'Haven がアップデートされました';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'あなたの識別情報と公開プロフィールは変更されていません。これらについて何かをする必要はありません。';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'セキュリティ向上のため、位置情報を再び共有するには、サークルを再作成し、メンバーを改めて招待する必要があります。';

  @override
  String get legacyCutoverExplainerAcknowledge => 'わかりました';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven は、最近のセキュリティアップデートに伴う一部の古いデータを破棄するよう、まだリレーに求めています。';

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
  String get refreshRingSemanticNoInbox => '受信トレイが未設定です。タップでリレー設定を開きます';

  @override
  String refreshRingSemanticChecking(int checked, int total) {
    final intl.NumberFormat checkedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String checkedString = checkedNumberFormat.format(checked);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString 件中 $checkedString 件のリレーを確認しました',
    );
    return '$_temp0';
  }

  @override
  String refreshRingSemanticAllOk(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'すべての $totalString 件のリレーが応答しました',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => '応答したリレーはありません';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString 件中 $okString 件のリレーが応答しました';
  }

  @override
  String get refreshRingAnnouncementChecking => 'リレーを確認しています';

  @override
  String get refreshRingAnnouncementAllOk => 'すべてのリレーが応答しました';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString 件中 $okString 件のリレーが応答しました';
  }

  @override
  String get refreshRingAnnouncementAllError => 'どのリレーにも接続できませんでした';

  @override
  String get refreshRingAnnouncementNoInbox => '受信トレイが未設定です';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'すべての $totalString 件のリレーにあなたのデータがあります',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'あなたのデータを持つリレーはありません';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString 件中 $okString 件のリレーにあなたのデータがあります';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'すべてのリレーにあなたのデータがあります';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString 件中 $okString 件のリレーにあなたのデータがあります';
  }

  @override
  String get refreshRingAnnouncementNoneFound => 'あなたのデータを持つリレーはありません';

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
  String get profileIsPublicNoticeTitle => 'プロフィールは公開されます';

  @override
  String get profileIsPublicNoticeBody =>
      'あなたの表示名と写真は、サークルのメンバーだけでなく、Nostr ネットワーク上の誰からも見えます。公開しても差し支えないものだけを共有してください。';

  @override
  String get identityRefreshProfileTooltip => '公開プロフィールを更新';

  @override
  String get identityAdvancedExportError => '秘密鍵を書き出せませんでした。もう一度お試しください。';

  @override
  String get identityAdvancedDeleteTitle => '識別情報を削除しますか？';

  @override
  String get identityAdvancedDeleteBody =>
      'これにより、この端末から識別情報とすべてのサークルのデータが削除されます。その識別情報ですでに公開したものは、そのまま残ります: 名前と鍵はそれらを保持しているリレーに、写真はそれを預かっている画像サーバーに残り続けます。あとでこの識別情報を復元したい場合は、秘密鍵をバックアップ済みであることを必ず確認してください。';

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
      'あなたの公開鍵は、共有しても安全なユーザー名のように働きます。人々はこのコードをスキャンするか、あなたの公開鍵を貼り付けて、あなたをサークルに招待します。これを共有しても、あなたの居場所が明らかになることはありません。あなたの表示名と写真はすでに公開されているので、これによって新たに分かることはありません。';

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
  String get circleMemberPublicKeyCopied => '公開鍵をクリップボードにコピーしました';

  @override
  String get circleMemberCopyPublicKeyHint => '公開鍵をコピー';

  @override
  String get circleMemberSetNicknameMenuItem => 'ニックネームを設定';

  @override
  String get circleMemberCopyPublicKeyMenuItem => '公開鍵をコピー';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'プロフィールを更新できませんでした。もう一度お試しください。';

  @override
  String get memberDetailSheetTitle => 'メンバーの詳細';

  @override
  String get memberNicknameSheetHint => 'ニックネームを入力してください';

  @override
  String get memberNicknameSheetLabel => 'ニックネーム';

  @override
  String get memberNicknameSheetSave => 'ニックネームを保存';

  @override
  String get memberNicknameSheetClear => 'ニックネームを消去';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'ニックネームを保存しました';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'ニックネームを消去しました';

  @override
  String get npubQrScanLabel => 'スキャンして追加';

  @override
  String get npubQrSemanticsLabel => 'あなたの公開識別情報のQRコード';

  @override
  String get photoHeaderRemoveTitle => 'プロフィール写真を削除しますか？';

  @override
  String get photoHeaderRemoveBody =>
      'これにより、あなたの公開プロフィールから写真が外されます。画像ファイルはそれを預かっているサーバーに残り、ほかの人がすでにダウンロードしたコピーも、その人たちの手元に残ります。';

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
      '写真を更新しました。あなたの公開 Nostr プロフィールに公開されました。';

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
  String get mapLocationNoPermissionTitle => 'Haven が位置情報を使用できません';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'この端末で位置情報がオフになったため、サークルへの共有を停止しました。位置情報をオンにすると再開します。';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven に位置情報の使用が許可されていないため、共有を停止しました。使用を許可すると再開します。';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      '端末の設定で Haven の位置情報の使用が許可されていないため、共有を停止しました。設定で許可すると再開します。';

  @override
  String get mapLocationSharingStoppedBoth =>
      '位置情報の共有を停止しました。この端末で位置情報をオンにし、Haven に使用を許可してください。';

  @override
  String get mapLocationSharingStoppedUnknown =>
      '位置情報を取得できなくなったため、共有を停止しました。位置情報がオンか、Haven に使用が許可されているかをご確認ください。';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      '位置情報が使えるようになりました。共有を再開しています';

  @override
  String get clockSkewTitle => 'この端末の時刻が正しくありません';

  @override
  String get clockSkewBodyRejected =>
      'この端末が付ける時刻をリレーが受け付けないため、サークルに位置情報が届いていません。端末の設定で日付と時刻の自動設定をオンにしてください。';

  @override
  String get clockSkewBodyBehind =>
      'この端末の時刻がサークルのほかのメンバーより遅れているため、送信された位置情報は誰にも見られないまま有効期限が切れています。端末の設定で日付と時刻の自動設定をオンにしてください。';

  @override
  String get clockSkewResolvedAnnouncement =>
      '時刻の問題が解消しました。Haven が位置情報の共有を再開しました';

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
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '。精度: $metersStringメートル';
  }

  @override
  String memberMarkerMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m';
  }

  @override
  String memberMarkerMinutesAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString分前',
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
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$nameは$direction方向の画面外にいます。タップして表示します';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'メンバーが$direction方向の画面外にいます。タップして表示します';
  }

  @override
  String get compassNorth => '北';

  @override
  String get compassNorthEast => '北東';

  @override
  String get compassEast => '東';

  @override
  String get compassSouthEast => '南東';

  @override
  String get compassSouth => '南';

  @override
  String get compassSouthWest => '南西';

  @override
  String get compassWest => '西';

  @override
  String get compassNorthWest => '北西';

  @override
  String get commonAdd => '追加';

  @override
  String get addRelaySheetTitleInbox => '受信トレイのリレーを追加';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage リレーを追加';

  @override
  String get addRelaySheetTitleProfile => 'プロフィールリレーを追加';

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
