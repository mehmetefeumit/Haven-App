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
  String get onboardingValueProp2Title => '誰にも止められない';

  @override
  String get onboardingValueProp3Title => 'アカウントは不要';

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
  String get settingsRelaysTitle => 'リレー';

  @override
  String get settingsLocationTitle => '位置情報';

  @override
  String get settingsLocationSubtitleOn => 'バックグラウンド共有はオンです';

  @override
  String get settingsLocationSubtitleOff => 'Haven を開いている間だけ';

  @override
  String get settingsMapStyleTitle => '地図のスタイル';

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
  String get locationSettingsBatteryOptNote =>
      'Haven はまだバッテリー最適化の対象になっています。一部の端末では、これによりバックグラウンド共有が予告なく停止されることがあります。共有を確実に続けるには、Haven を対象から除外してください。';

  @override
  String get locationSettingsErrorSnack => '問題が発生しました';

  @override
  String get locationSettingsIntro =>
      'Haven は、アプリを開いている間は常に、あなたの位置情報をサークルに共有します。これをオンにすると、Haven がバックグラウンドにある間もサークルのメンバーは位置情報を見続けられます。システムが Haven を終了させると、あなた自身の共有は停止し、その後も Haven はサークルの位置情報を受け取るために起動することはありますが、あなたの位置情報を送るために起動することはありません。Android では、Haven をスワイプして最近使ったアプリから消しても共有は動き続け、端末を再起動したあとには共有が自動的にまた始まります。iPhone では、あなたが Haven を開くまで共有は停止したままです。';

  @override
  String get locationSettingsToggleTitle => 'バックグラウンドで共有';

  @override
  String get locationSettingsToggleSubtitle => 'Haven がバックグラウンドにある間も共有を続けます';

  @override
  String get locationSettingsIosLimitedNote =>
      '現在の権限のままでも、バックグラウンドでの共有は継続され、その間 iOS は画面上部に青い位置情報バーを表示します。設定で Haven の位置情報を「常に」にすると、iOS がアプリを終了した後も、Haven がサークルの位置情報に追いつけるようになります。ただし「常に」では、iOS はこの位置情報バーの代わりに、ステータスバーに位置情報の矢印を表示することがあります。あなた自身の位置情報の共有は、Haven を開き直したときに再開されます。';

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
      'バックグラウンド共有がオンの間、Haven は位置情報のセッションを維持し、サークルのメンバーがあなたを見失わないようにします。';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'iOS は、Haven が位置情報を使用している間、ステータスバーに位置情報の矢印を表示します。その後もしばらくの間、「位置情報サービス」の設定で Haven の隣に同じ矢印が表示されたままになります。';

  @override
  String get locationSettingsIosIndicatorBar =>
      '位置情報の権限が「常に」になっている場合、Haven が位置情報を使用している間、iOS は画面上部に青い位置情報バーを表示します。';

  @override
  String get locationDisclosureTitle => '位置情報の共有について';

  @override
  String get locationDisclosureWhy =>
      'Haven は、あなたが選んだサークルのメンバーに、あなたの現在地をリアルタイムで表示します。メンバーの現在地も、地図上であなたに表示します。そのため Haven には、端末の正確な位置情報を使用する権限が必要です。';

  @override
  String get locationDisclosureHow =>
      'あなたの位置情報は端末上でエンドツーエンドで暗号化されます。そのため、読めるのはあなたが選んだサークルのメンバーだけで、Haven には読めません。Haven には自前のサーバーがありません。暗号化されたあなたの更新は、ほかの人たちが運営する独立したリレーを経由します。リレーはあなたのネットワークアドレスを見ることはできますが、あなたがどこにいるかを知ることはありません。地図を描くために、Haven は Stadia Maps にあなたとサークルの周辺の地域を要求します。そのため Stadia Maps はその場所をおおまかに知ることになりますが、あなたの名前も、あなたの鍵も、サークルのメンバーが誰かも知ることはありません。Stadia Maps は、個人情報を販売も交換もしないこと、端末にクッキーを保存しないこと、サーバーのログを約2週間保持することを表明しています。これは Stadia Maps 自身の方針であり、Haven がその順守を強制することはできません。';

  @override
  String get locationDisclosureSharing =>
      'Haven を開いていて、あなたがサークルに参加している間、あなたの位置情報は数分おきに自動で送信されます。一時停止する方法はありません。あるサークルとの共有をやめるには、そのサークルを退出してください。';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'このアプリは、アプリが閉じているときや使用していないときでも、サークルとの共有を可能にするために位置情報データを使用します。';

  @override
  String get locationDisclosureBackgroundIos =>
      'このアプリは、Haven がバックグラウンドにあって使用していないときでも、サークルとの共有を可能にするために位置情報データを使用します。iOS が Haven を終了させると、あなたが開き直すまで共有は停止し、その後も Haven はサークルの位置情報を受け取るために起動することはありますが、あなたの位置情報を送るために起動することはありません。';

  @override
  String get locationDisclosureManage => 'バックグラウンド共有は、設定 → 位置情報 からいつでもオフにできます。';

  @override
  String get locationDisclosureAgree => '同意する';

  @override
  String get locationDisclosureNotNow => '今はしない';

  @override
  String get fgsNotificationSharing => 'Haven が位置情報を送受信しています';

  @override
  String get fgsNotificationPaused => 'Haven は一時停止中です。アプリを開くと共有を再開します';

  @override
  String get fgsNotificationOpen => 'Haven は画面に表示されています';

  @override
  String get fgsChannelName => '位置情報の共有';

  @override
  String get fgsChannelDescription =>
      'Haven がバックグラウンドにある間も、暗号化された位置情報の共有を続けます。';

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
  String get aboutFooterLicense => 'MIT License のもとで提供されています';

  @override
  String aboutFooterVersion(String version) {
    return 'バージョン $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven には自前のサーバーがありません。暗号化されたあなたの更新は、「リレー」と呼ばれる独立したサーバーを経由します。リレーが、あなたの位置情報やメッセージを読むことはできません。';

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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return '同時に参加できるサークルは$limitString個までです。新しく作るには、いずれかのサークルを退出してください。';
  }

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
  String get memberPickerSectionRoster => 'あなたのサークルのメンバー';

  @override
  String get memberPickerTierRoster => 'あなたのサークルのメンバーです';

  @override
  String get memberPickerNoMatches => 'あなたのサークルには一致するメンバーがいません';

  @override
  String get memberPickerLoading => 'あなたのサークルのメンバーを読み込んでいます';

  @override
  String get memberPickerDirectoryUnavailable => '今はあなたのサークルのメンバーを読み込めません';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '一致するメンバー: $countString人';
  }

  @override
  String get memberPickerReasonSelf => 'これはあなた自身のIDです';

  @override
  String get memberPickerReadPublicKey => '公開鍵を読み上げる';

  @override
  String get memberPickerSectionRecent => '最近あなたのサークルにいた人';

  @override
  String get memberPickerTierRecent => '最近あなたのサークルにいました';

  @override
  String get memberPickerNicknameNote => 'あなたが設定したニックネームで、相手が公開している名前ではありません';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'サークル: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven は、この人が公開している名前を1つのリレーに問い合わせました。そのリレーには、この端末がたった今この鍵について問い合わせたことが分かります。ただし、この問い合わせには署名が付いていないため、Haven でのあなたの識別情報とは結びつきません。写真はまだダウンロードしていません。';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'ほか$countString人';
  }

  @override
  String get invitationCardHeading => 'サークルへの招待';

  @override
  String invitationCardSemantics(String inviter) {
    return 'サークルへの招待が $inviter から届いています';
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
  String get invitationCardNicknameNote => 'あなたが設定したニックネームで、相手が公開している名前ではありません';

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
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return '同時に参加できるサークルは$limitString個までです。この招待はそのまま残るので、いずれかのサークルを退出してから承認してください。';
  }

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
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta・位置情報の有効期限$expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString分',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySecondsShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString秒',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpiryMinutesLong(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '約$countString分',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySecondsLong(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString秒',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta。Haven はリレーに対し、あなたがこのサークルに送る位置情報の更新を$expiry後に破棄するよう求めます。';
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
  String get profileSyncStatusSyncing => '公開プロフィールに同期しています…';

  @override
  String get profileSyncStatusPartial => '公開済み。一部のリレーはまだ同期中です';

  @override
  String get profileSyncStatusSynced => '公開プロフィールは最新の状態です';

  @override
  String get profileSyncStatusFailed => 'まだ同期できていません。';

  @override
  String get profileSyncStatusRetrySemantics => 'プロフィールの公開を再試行';

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
      '写真を更新しました。あなたの Nostr の公開プロフィールに公開されます。';

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
  String get clockSkewTitleDisagreement => 'いずれかのサークルに時刻が正しくない端末があります';

  @override
  String get clockSkewBodyDisagreement =>
      'この端末の時刻と、別のメンバーの端末の時刻が2分以上ずれています。もし間違っているのがこの端末の時刻であれば、送信する位置情報が誰にも見られないまま有効期限が切れるおそれがあります。少なくともこの端末が原因ではないことを確かめるには、端末の設定で日付と時刻の自動設定をオンにしてください。';

  @override
  String get clockSkewDisagreementResolvedAnnouncement => '時刻の警告が消えました';

  @override
  String get sharingHealthTitleStopped => '位置情報の共有が停止しました';

  @override
  String get sharingHealthTitleNotSending => '自分の位置情報が共有されていません';

  @override
  String get sharingHealthTitleNotReceiving => 'ほかのメンバーの位置情報が届いていません';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '約$countString分間、更新なし',
    );
    return '$_temp0';
  }

  @override
  String sharingHealthNoUpdatesHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '約$countString時間、更新なし',
    );
    return '$_temp0';
  }

  @override
  String sharingHealthNoUpdatesDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '約$countString日間、更新なし',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => '修復';

  @override
  String get sharingHealthRepairUnavailableHint => 'このサークルでは修復を利用できません';

  @override
  String get sharingHealthRepairHint =>
      'リレーに接続し直して、位置情報の送信をやり直し、あなたがこのサークルの管理者の場合は、新しい鍵に切り替えることがあります';

  @override
  String get sharingHealthRepairSent =>
      '修復を送信しました。ほかのメンバーには、それぞれの端末が受け取ってから反映されます。';

  @override
  String get sharingHealthRepairNotOwner =>
      'このサークルを修復できるのは管理者だけです。あなたを削除して、もう一度追加するよう管理者に頼んでください。';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'このサークルはこの端末では修復できません。同じメンバーで新しいサークルを作成してください。';

  @override
  String get sharingHealthRepairNothingToDo =>
      '今のところ修復は必要ありません。Haven が自動で試し続けます。';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement => '位置情報の共有はまだ復旧していません';

  @override
  String get sharingHealthResumedAnnouncement => '位置情報の共有が復旧しました';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '最終確認 $countString分前',
    );
    return '$_temp0';
  }

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
