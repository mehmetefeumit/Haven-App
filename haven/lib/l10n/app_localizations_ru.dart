// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appearanceTitle => 'Оформление';

  @override
  String get appearanceThemeHeader => 'Тема';

  @override
  String get appearanceThemeSystem => 'Как в системе';

  @override
  String get appearanceThemeSystemSubtitle => 'Следовать настройкам устройства';

  @override
  String get appearanceThemeLight => 'Светлая';

  @override
  String get appearanceThemeLightSubtitle => 'Всегда светлая тема';

  @override
  String get appearanceThemeDark => 'Тёмная';

  @override
  String get appearanceThemeDarkSubtitle => 'Всегда тёмная тема';

  @override
  String get appearanceLanguageTitle => 'Язык';

  @override
  String get languageSystemDefault => 'Как в системе';

  @override
  String get commonTryAgain => 'Повторить';

  @override
  String get commonDismiss => 'Закрыть';

  @override
  String get commonSettings => 'Настройки';

  @override
  String get commonInvitations => 'Приглашения';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString ожидающего приглашения',
      many: '$countString ожидающих приглашений',
      few: '$countString ожидающих приглашения',
      one: '$countString ожидающее приглашение',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Назад';

  @override
  String get commonContinue => 'Продолжить';

  @override
  String get commonSkip => 'Пропустить';

  @override
  String get commonRetry => 'Повторить';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Шаг $currentString из $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Делитесь своим местоположением приватно, только с теми, с кем хотите.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'только';

  @override
  String get onboardingWelcomeCta => 'Начать';

  @override
  String get onboardingValuePropsTitle => 'Чем отличается Haven';

  @override
  String get onboardingValueProp1Title => 'Вас видят только ваши круги';

  @override
  String get onboardingValueProp1Body =>
      'Ваше местоположение шифруется прямо на устройстве, ещё до отправки, поэтому прочитать его могут только выбранные вами круги — никогда Haven и никто другой. А поскольку Haven имеет открытый исходный код, в этом может убедиться любой.';

  @override
  String get onboardingValueProp2Title => 'Никто не может его отключить';

  @override
  String get onboardingValueProp2Body =>
      'У Haven нет центрального сервера. Ваши зашифрованные сообщения идут через децентрализованную сеть реле, которые вы выбираете сами, поэтому ни одна сторона не может всё отключить.';

  @override
  String get onboardingValueProp3Title => 'Аккаунт не нужен';

  @override
  String get onboardingValueProp3Body =>
      'Никакой почты, телефона или регистрации. Haven создаёт приватную личность, которая хранится только на вашем телефоне, и ничто не связывает её с вами настоящим.';

  @override
  String get onboardingValueProp1Summary =>
      'Шифруется на устройстве — прочитают только выбранные вами круги.';

  @override
  String get onboardingValueProp2Summary =>
      'Без центрального сервера — работает через сеть реле, которую выбираете вы.';

  @override
  String get onboardingValueProp3Summary =>
      'Ни почты, ни телефона, ни регистрации. Ничто не связывает это с вами.';

  @override
  String get onboardingCreateIdentityTitle => 'Создайте свою личность';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven создаст приватную личность, которая будет храниться только на этом телефоне. Именно по ней вас узнают ваши круги.';

  @override
  String get onboardingCreateIdentityWarning =>
      'Если вы потеряете этот телефон или удалите приложение, ваша личность исчезнет. Haven не сможет её восстановить.';

  @override
  String get onboardingCreateIdentityCta => 'Создать личность';

  @override
  String get onboardingCreateIdentityLoading => 'Настраиваем…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'Уже есть ключ?';

  @override
  String get onboardingCreateIdentityImportLink => 'Импортировать его';

  @override
  String get onboardingCreateIdentityError =>
      'Не удалось создать личность. Пожалуйста, повторите попытку.';

  @override
  String get onboardingImportTitle => 'Импортируйте существующий ключ';

  @override
  String get onboardingImportBody =>
      'Вставьте секретный ключ, который вы сохранили из другого совместимого с Haven приложения.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'Импортировать';

  @override
  String get onboardingImportLoading => 'Импортируем…';

  @override
  String get onboardingImportInvalid =>
      'Это не похоже на действительный ключ для восстановления. Проверьте и попробуйте снова.';

  @override
  String get onboardingImportError =>
      'Не удалось импортировать этот ключ. Проверьте и попробуйте снова.';

  @override
  String get onboardingDisplayNameHint => 'например, Алекс';

  @override
  String get onboardingDisplayNameError =>
      'Не удалось сохранить имя. Пожалуйста, повторите попытку.';

  @override
  String get commonCancel => 'Отмена';

  @override
  String get commonOpenSettings => 'Открыть настройки';

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get settingsIdentityTitle => 'Личность';

  @override
  String get settingsIdentitySubtitle => 'Профиль, ключи и обмен фото';

  @override
  String get settingsRelaysTitle => 'Реле';

  @override
  String get settingsRelaysSubtitle => 'Где вас находят приглашения';

  @override
  String get settingsLocationTitle => 'Местоположение';

  @override
  String get settingsLocationSubtitle => 'Фоновый обмен и разрешения';

  @override
  String get settingsMapStyleTitle => 'Стиль карты';

  @override
  String get settingsAppearanceSubtitle => 'Тема и язык';

  @override
  String get settingsAboutTitle => 'О приложении';

  @override
  String get settingsDebugOverlayTitle => 'Оверлей журнала отладки';

  @override
  String get settingsDebugOverlaySubtitle => 'Показывать журнал на экране';

  @override
  String get relaySettingsTitle => 'Реле';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Проверить реле';

  @override
  String get relaySettingsNoIdentityTitle => 'Нет личности';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Сначала создайте личность, чтобы управлять реле.';

  @override
  String get relaySettingsLoadIdentityError => 'Не удалось загрузить личность.';

  @override
  String get relaySettingsInboxTitle => 'Мои входящие реле';

  @override
  String get relaySettingsInboxSubtitle =>
      'kind 10050, куда приходят приглашения для вас';

  @override
  String get relaySettingsKeyPackageTitle => 'Мои реле KeyPackage';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051, где приглашающие находят ваши ключи шифрования';

  @override
  String get relaySettingsLoadRelaysError => 'Не удалось загрузить реле.';

  @override
  String get relaySettingsAddRelay => 'Добавить реле';

  @override
  String get relaySettingsRestoreDefaults => 'Восстановить по умолчанию';

  @override
  String get relaySettingsAddRelayError => 'Не удалось добавить реле.';

  @override
  String get relaySettingsRemoveRelayError => 'Не удалось удалить реле.';

  @override
  String get relaySettingsRestoreTitle => 'Восстановить реле по умолчанию?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Ваши текущие $countString реле будут заменены реле Haven по умолчанию. Это действие нельзя отменить.',
      many:
          'Ваши текущие $countString реле будут заменены реле Haven по умолчанию. Это действие нельзя отменить.',
      few:
          'Ваши текущие $countString реле будут заменены реле Haven по умолчанию. Это действие нельзя отменить.',
      one:
          'Ваше текущее $countString реле будет заменено реле Haven по умолчанию. Это действие нельзя отменить.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Восстановить';

  @override
  String get relaySettingsRestoreSuccess =>
      'Значения по умолчанию восстановлены.';

  @override
  String get relaySettingsRestoreError =>
      'Не удалось восстановить значения по умолчанию.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'Удалить $url';
  }

  @override
  String get relaySettingsStatusConnected => 'Подключено';

  @override
  String get relaySettingsStatusChecking => 'Проверка';

  @override
  String get relaySettingsStatusUnreachable => 'Недоступно';

  @override
  String get relaySettingsStatusNotChecked => 'Не проверено';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'Статус реле: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'Реле не настроены';

  @override
  String get relaySettingsEmptyMessage =>
      'Нужно хотя бы одно реле, чтобы вас могли найти. Нажмите ниже, чтобы восстановить реле Haven по умолчанию.';

  @override
  String get relaySettingsExplainerSemantics => 'Как работают реле Haven';

  @override
  String get relaySettingsExplainerHeading => 'Как это работает';

  @override
  String get relaySettingsExplainerNostr =>
      'У Haven нет центрального сервера. Он работает на двух открытых технологиях. Nostr — это сеть независимых серверов, называемых реле, которые может запустить кто угодно; они принимают ваши сообщения, недолго хранят их и передают дальше, когда их запрашивают ваши контакты. Ни одно реле не является незаменимым, поэтому, если одно отключится, остальные продолжат работать, а всё, что реле могли бы быть вынуждены передать, — это всегда лишь зашифрованные данные.';

  @override
  String get relaySettingsExplainerMarmot =>
      'Протокол Marmot шифрует ваши сообщения прямо на устройстве, ещё до отправки, используя стандарт MLS (Messaging Layer Security). Каждый круг — это отдельная зашифрованная группа со своими ключами, поэтому разные круги нельзя связать между собой. Эти ключи к тому же постоянно обновляются со временем — свойство, называемое прямой секретностью, — поэтому даже ключ, раскрытый позже, не сможет открыть ваши прежние сообщения.';

  @override
  String get relaySettingsExplainerMetadata =>
      'Благодаря этому реле никогда не видит ни вашего местоположения, ни сообщений, ни состава ваших кругов, ни вашей личности в этих сообщениях. Каждое сообщение публикуется с нового одноразового адреса отправки, поэтому ничто в сообщении не связывает его с вашим аккаунтом. Тем не менее реле всё же видит некоторые метаданные: случайную метку для каждого круга, время и размер вашего трафика, а также сетевой адрес, с которого вы подключаетесь.';

  @override
  String get relaySettingsExplainerInboxTerm => 'Входящие реле';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' — это ваш почтовый ящик: сюда доставляются приглашения вступить в круг, сами по себе зашифрованные, чтобы вы могли их забрать. Чтобы вас пригласить, человек должен иметь доступ к одному из этих реле.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'Реле KeyPackage';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' — это место, где вы публикуете небольшой набор своих публичных ключей, которым безопасно делиться. Тот, кто знает ваш аккаунт, забирает его с этих реле, чтобы добавить вас в круг.';

  @override
  String get relaySettingsExplainerOwnRelayTerm =>
      'Использование собственного реле.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' У каждого круга также есть свой список реле, который сообщается каждому участнику при вступлении; именно по этому списку, а не через ваш почтовый ящик, идут текущие зашифрованные обновления круга. Поэтому, если вы предпочитаете не пользоваться публичными реле, вы можете запустить собственное и привязать к нему круг: после того как все вступят, трафик этого круга сможет идти только через него.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'Загвоздка — в доступности.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' Каждый участник должен иметь возможность подключиться к этому реле, а когда вы впервые приглашаете кого-то, вам нужно реле, доступное вам обоим (например, одно и то же приватное реле, указанное у всех как входящее реле и реле KeyPackage). Приватное реле всё так же видит тот же зашифрованный трафик и его время, что и любое другое; вы лишь контролируете, кто им управляет.';

  @override
  String get relaySettingsExplainerFooter =>
      'Вы можете в любой момент добавлять или удалять реле в любом из списков. Больше реле — проще вас найти; меньше — больше контроля над тем, куда идёт ваш зашифрованный трафик.';

  @override
  String get locationSettingsTitle => 'Местоположение';

  @override
  String get locationSettingsDisabledSnack => 'Фоновый обмен отключён';

  @override
  String get locationSettingsEnabledSnack => 'Фоновый обмен включён';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'Для фонового обмена нужно уведомление, чтобы Android не останавливал его. Пока он выключен. Разрешите уведомления для Haven, чтобы включить его.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'Включено. На некоторых телефонах оптимизация батареи может приостанавливать обмен. Исключите Haven из оптимизации батареи, чтобы он работал надёжно.';

  @override
  String get locationSettingsErrorSnack => 'Что-то пошло не так';

  @override
  String get locationSettingsIntro =>
      'Когда фоновый обмен включён, ваши круги продолжают видеть ваше местоположение в реальном времени, даже когда Haven закрыт.';

  @override
  String get locationSettingsToggleTitle => 'Делиться в фоне';

  @override
  String get locationSettingsToggleSubtitle =>
      'Продолжать делиться при закрытом приложении';

  @override
  String get locationSettingsIosLimitedNote =>
      'Ограничено в фоне. Установите для Haven доступ к геопозиции «Всегда» в Настройках';

  @override
  String get locationSettingsAndroidHeader => 'Настройки ОС для надёжности';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven нужно постоянное уведомление, чтобы Android поддерживал работу фоновой службы. Если вы отклонили разрешение на уведомления, откройте Настройки и разрешите уведомления для Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'Для надёжного фонового обмена также исключите Haven из оптимизации батареи. Перейдите в Настройки → Приложения → Haven → Батарея → Без ограничений.';

  @override
  String get locationSettingsAndroidVendors =>
      'На устройствах Samsung уберите Haven из «Спящих приложений» (Обслуживание устройства → Батарея → Ограничения фоновой работы). На Xiaomi включите автозапуск для Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'Для непрерывного фонового обмена установите для Haven доступ к геопозиции «Всегда» в Настройках. iOS показывает синий индикатор в строке состояния, пока приложение использует ваше местоположение в фоне.';

  @override
  String get mapStyleTitle => 'Стиль карты';

  @override
  String get mapStyleMinimalTitle => 'Минимальный';

  @override
  String get mapStyleMinimalSubtitle =>
      'Спокойный, малодетализированный фон, следующий за вашей светлой или тёмной темой';

  @override
  String get mapStyleDetailedTitle => 'Подробный';

  @override
  String get mapStyleDetailedSubtitle => 'Полноцветные улицы, подписи и места';

  @override
  String get mapStyleOutdoorsTitle => 'Природа';

  @override
  String get mapStyleOutdoorsSubtitle => 'Рельеф с тропами и парками';

  @override
  String get mapStylePreviewHeader => 'Предпросмотр';

  @override
  String get mapStylePreviewCity => 'Город';

  @override
  String get mapStylePreviewNature => 'Природа';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Предпросмотр карты ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Предпросмотр карты недоступен в этой сборке';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'Живой предпросмотр доступен в релизных сборках';

  @override
  String get aboutTitle => 'О приложении';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'Приватный и устойчивый к цензуре обмен местоположением.';

  @override
  String get aboutLicensesTitle => 'Лицензии открытого кода';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'Сообщить об ошибке на карте';

  @override
  String get aboutSupportOsm => 'Поддержать OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nКартографические данные под лицензией ODbL';

  @override
  String get aboutLinkOpenError => 'Не удалось открыть ссылку';

  @override
  String get aboutWhoCanSeeTitle => 'Кто что видит';

  @override
  String get aboutWhoCanSeeIntro =>
      'Ваше точное местоположение могут прочитать только выбранные вами люди. Вот что основные стороны могут и не могут видеть.';

  @override
  String get aboutActorCirclesWho => 'Участники кругов, с которыми вы делитесь';

  @override
  String get aboutActorCirclesSees =>
      'Ваше точное местоположение и выбранное вами отображаемое имя, но только внутри тех кругов, где вы ими делитесь, — никогда в других ваших кругах.';

  @override
  String get aboutActorRelaysWho => 'Операторы реле';

  @override
  String get aboutActorRelaysSees =>
      'Серверы, которые передают ваши сообщения дальше. Они видят ваш IP-адрес, публичный ключ, под которым вы публикуетесь (случайный идентификатор, а не ваше имя), размер и время вашего трафика, а также то, какой аккаунт вы искали, когда кого-то находили. Они никогда не могут прочитать ваше местоположение, ваши сообщения, названия ваших кругов или их состав.';

  @override
  String get aboutActorMapWho => 'Поставщик карт (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'Только пока карта открыта: ваш IP-адрес и область, которую вы просматриваете, чтобы прислать нужные фрагменты карты. Никогда — ваши круги или ваше местоположение, которым вы делитесь. Stadia анонимизирует IP-адреса и не продаёт ваши данные.';

  @override
  String get aboutActorDevelopersWho => 'Разработчики Haven';

  @override
  String get aboutActorDevelopersSees =>
      'Ничего. У Haven нет собственных серверов, и он не собирает аналитику. Разработчик мог бы увидеть лишь то, что видит оператор реле, и только если вы пользовались реле, которым он случайно управляет.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'И всё же ваша активность не невидима. Реле, которым вы пользуетесь, или любой, кто наблюдает за вашей сетью, может по времени подключений и размерам сообщений понять, что вы активны, примерно когда и как часто.';

  @override
  String get aboutScreenshotTitle => 'Защита от снимков экрана';

  @override
  String get aboutScreenshotBody =>
      'На Android Haven блокирует снимки экрана и запись экрана во всём приложении, чтобы предотвратить случайное раскрытие местоположения. Это защита на уровне системы (FLAG_SECURE), которая распространяется на каждый экран приложения, включая карту и списки участников.';

  @override
  String get aboutVpnTitle => 'Больше приватности с VPN';

  @override
  String get aboutVpnBody =>
      'Реле и поставщик карт видят ваш IP-адрес, а ваш интернет-провайдер видит, к каким серверам вы обращаетесь. Надёжный VPN скрывает от них ваш IP-адрес. Мы рекомендуем Mullvad. Это не меняет того, что видят участники ваших кругов, и переносит доверие на поставщика VPN.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Распространяется под лицензией MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Версия $version';
  }

  @override
  String get commonClearAll => 'Очистить всё';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString участника',
      many: '$countString участников',
      few: '$countString участника',
      one: '$countString участник',
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
  String get circlesTitle => 'Круги';

  @override
  String get circlesRefreshTooltip => 'Обновить круги';

  @override
  String get circlesRequiresIdentity =>
      'Для создания круга сначала нужно настроить личность';

  @override
  String get circlesCreateCta => 'Создать круг';

  @override
  String get circlesYourCircles => 'Ваши круги';

  @override
  String get circlesEmptyTitle => 'Кругов пока нет';

  @override
  String get circlesEmptyMessage =>
      'Создайте круг, чтобы начать делиться местоположением с близкими друзьями и семьёй.';

  @override
  String get circlesSheetEmptyMessage =>
      'Создайте круг, чтобы начать делиться местоположением с доверенными контактами.';

  @override
  String get circlesLoadError => 'Не удалось загрузить круги';

  @override
  String get circlesSelectToView => 'Выберите круг, чтобы увидеть участников';

  @override
  String get circlesNoMembers => 'В этом круге нет участников';

  @override
  String get createCircleTitle => 'Добавить участников';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Выбрано ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Добавьте участников круга';

  @override
  String get createCircleEmptyMessage =>
      'Найдите по ID или отсканируйте QR-код, чтобы добавить участников.';

  @override
  String get createCircleNoValidMembers =>
      'Нет подходящих участников для приглашения';

  @override
  String get createCircleMemberAlreadyAdded => 'Участник уже добавлен';

  @override
  String get createCircleNoIdInQr => 'В QR-коде не найден действительный ID';

  @override
  String get createCircleNoAccountFound => 'Аккаунт Haven не найден';

  @override
  String get createCircleCouldNotVerify => 'Не удалось проверить участника';

  @override
  String get createCircleSomethingWentWrong => 'Что-то пошло не так';

  @override
  String get nameCircleTitle => 'Назовите свой круг';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Будет приглашено $countString участника',
      many: 'Будут приглашены $countString участников',
      few: 'Будут приглашены $countString участника',
      one: 'Будет приглашён $countString участник',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Название круга';

  @override
  String get nameCircleNameHint => 'например, Семья, Близкие друзья';

  @override
  String get nameCircleNameEmptyError => 'Пожалуйста, введите название круга';

  @override
  String get nameCircleNameTooLongError =>
      'Название не должно превышать 50 символов';

  @override
  String get nameCircleSharingInfo =>
      'Все в этом круге видят местоположение и отображаемое имя друг друга. Ваше отображаемое имя — то, что вы задали в Настройки → Личность. Этот круг остаётся отдельным от любых других, в которых вы состоите, поэтому его участники не видят ни ваших других кругов, ни их состава.';

  @override
  String get nameCircleCreateCta => 'Создать круг';

  @override
  String get nameCircleStageCreatingGroup => 'Создаём защищённую группу...';

  @override
  String get nameCircleStageSendingInvites => 'Отправляем приглашения...';

  @override
  String get nameCircleStageComplete => 'Готово!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Ход создания: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return 'Выполнено $percentString процентов';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Круг «$name» создан! Отправлено $countString приглашения.',
      many: 'Круг «$name» создан! Отправлено $countString приглашений.',
      few: 'Круг «$name» создан! Отправлено $countString приглашения.',
      one: 'Круг «$name» создан! Отправлено $countString приглашение.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Ошибка личности. Пожалуйста, проверьте настройку личности.';

  @override
  String get nameCircleCreateError =>
      'Не удалось создать круг. Пожалуйста, повторите попытку.';

  @override
  String addMemberTitle(String circleName) {
    return 'Добавить в $circleName';
  }

  @override
  String get addMemberInfo =>
      'Новые участники смогут видеть зашифрованные местоположения этого круга после того, как примут приглашение.';

  @override
  String get addMemberAlreadyInCircle => 'Уже в этом круге';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Отправить приглашения',
      many: 'Отправить приглашения',
      few: 'Отправить приглашения',
      one: 'Отправить приглашение',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Отправляем приглашения...',
      many: 'Отправляем приглашения...',
      few: 'Отправляем приглашения...',
      one: 'Отправляем приглашение...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Приглашения отправлены в $circleName',
      many: 'Приглашения отправлены в $circleName',
      few: 'Приглашения отправлены в $circleName',
      one: 'Приглашение отправлено в $circleName',
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

    return 'Приглашения отправлены ($sentString из $totalString). Доставка остальных ожидается.';
  }

  @override
  String get addMemberError =>
      'Не удалось добавить участника. Пожалуйста, повторите попытку.';

  @override
  String get qrScannerTitle => 'Сканировать QR-код';

  @override
  String get qrScannerToggleFlash => 'Включить вспышку';

  @override
  String get qrScannerSwitchCamera => 'Сменить камеру';

  @override
  String get qrScannerInstruction => 'Наведите рамку на QR-код';

  @override
  String get qrScannerScanning => 'Сканирование...';

  @override
  String get circleMemberInvitationPending => 'Приглашение ожидает ответа';

  @override
  String get circleMemberNoRecentLocation => 'Нет недавнего местоположения';

  @override
  String get circleMemberRemoveTooltip => 'Удалить из круга';

  @override
  String get circleMemberAdmin => 'Админ';

  @override
  String get circleMemberHintPending => 'приглашение ожидает ответа';

  @override
  String get circleMemberHintNoLocation => 'местоположение недоступно';

  @override
  String get circleMemberHintMember => 'участник';

  @override
  String get circleMemberHintTapToCenter =>
      'нажмите, чтобы центрировать карту на их местоположении';

  @override
  String get pendingMemberRetryTooltip => 'Повторить проверку';

  @override
  String get pendingMemberRemoveTooltip => 'Удалить участника';

  @override
  String get pendingMemberValidating => 'Проверка';

  @override
  String get pendingMemberValid => 'Подходит';

  @override
  String get pendingMemberWarning => 'Предупреждение';

  @override
  String get pendingMemberCheckingAvailability => 'Проверяем доступность...';

  @override
  String get pendingMemberReadyToInvite => 'Готово к приглашению';

  @override
  String get pendingMemberNeedsUpdate => 'Требуется обновить Haven';

  @override
  String get memberSearchHint => 'Введите ID участника...';

  @override
  String get memberSearchPasteTooltip => 'Вставить из буфера обмена';

  @override
  String get memberSearchAddTooltip => 'Добавить участника';

  @override
  String get memberSearchScanTooltip => 'Сканировать QR-код';

  @override
  String get memberSearchHelper =>
      'Попросите у контактов их QR-код или ID в Haven';

  @override
  String get memberSearchNoValidId => 'Действительный ID Haven не найден';

  @override
  String get memberSearchAlreadyAdded => 'Участник уже добавлен';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+ещё $countString';
  }

  @override
  String get invitationStatusPending => 'Приглашение ожидает ответа';

  @override
  String get invitationStatusActive => 'Активен';

  @override
  String get invitationStatusDeclined => 'Отклонено';

  @override
  String invitationStatusSemantics(String label) {
    return 'Статус приглашения: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Приглашение вступить в $circleName от $inviter, участников: $countString';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Пригласил криптографический идентификатор $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Пригласил: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString участника',
      many: '$countString участников',
      few: '$countString участника',
      one: '$countString участник',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'Только что';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d назад';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h назад';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m назад';
  }

  @override
  String get invitationCardDecline => 'Отклонить';

  @override
  String get invitationCardAccept => 'Принять';

  @override
  String get invitationAcceptedSnack => 'Приглашение принято';

  @override
  String get invitationDeclinedSnack => 'Приглашение отклонено';

  @override
  String get invitationAcceptError =>
      'Не удалось принять приглашение. Пожалуйста, повторите попытку.';

  @override
  String get invitationDeclineError =>
      'Не удалось отклонить приглашение. Пожалуйста, повторите попытку.';

  @override
  String get circleSelectorLabel => 'Выбор круга';

  @override
  String get circleSelectorPlaceholder => 'Выберите круг';

  @override
  String get circleSelectorNewCircle => 'Новый круг';

  @override
  String get circleSelectorLoadError => 'Не удалось загрузить круги';

  @override
  String get circleSelectorExpandedAnnouncement => 'Список кругов развёрнут';

  @override
  String get circleSelectorCollapsedAnnouncement => 'Список кругов свёрнут';

  @override
  String get circleDetailsButtonTooltip => 'Сведения о круге';

  @override
  String get circleDetailsTitle => 'Сведения о круге';

  @override
  String get circleDetailsRelaysHeading => 'Реле для этого круга';

  @override
  String get circleDetailsNoRelays => '(не указаны)';

  @override
  String get circleDetailsRelaysNote =>
      'Эти реле были выбраны при создании круга и пока не редактируются. Они не зависят от ваших личных настроек реле.';

  @override
  String get circleDetailsAddMember => 'Добавить участника';

  @override
  String get circleDetailsLeaveCircle => 'Покинуть круг';

  @override
  String get leaveCircleDialogTitle => 'Покинуть круг';

  @override
  String get leaveCircleDialogBody =>
      'Вы уверены, что хотите покинуть этот круг? Вы больше не будете получать обновления местоположения от его участников. Это действие нельзя отменить.';

  @override
  String get leaveCircleConfirm => 'Покинуть';

  @override
  String get leaveCircleIdentityUnavailable => 'Личность недоступна';

  @override
  String get leaveCircleSuccess => 'Вы покинули круг';

  @override
  String get leaveCircleError => 'Не удалось покинуть круг';

  @override
  String get leaveCircleAdminLimitationNote =>
      'Как администратор этого круга вы можете покинуть его только после того, как это сделают все остальные участники. Мы понимаем, что это неудобно, — в будущем обновлении администраторы смогут передавать свою роль и покидать круг напрямую.';

  @override
  String get circleBlockedBannerTitle => 'Этот круг нельзя обновить';

  @override
  String get circleBlockedBannerBody =>
      'Что-то пошло не так с шифрованием этого круга, поэтому Haven больше не может отправлять и получать в нём обновления. Ниже по-прежнему доступно последнее известное состояние, или вы можете покинуть круг.';

  @override
  String get legacyCircleBannerTitle => 'Этот круг нужно создать заново';

  @override
  String get legacyCircleBannerBody =>
      'Механизм шифрования Haven был обновлён, поэтому этот круг больше нельзя использовать. Создайте его заново, чтобы продолжить делиться местоположением с теми же людьми — вам нужно будет пригласить их снова.';

  @override
  String get legacyCircleRecreateCta => 'Создать круг заново';

  @override
  String get legacyCircleRemoveCta => 'Удалить';

  @override
  String get legacyCircleRemoveDialogTitle => 'Удалить круг?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'Этот круг больше нельзя использовать, и он будет удалён из вашего списка. Это не повлияет на новый круг, который вы создадите взамен.';

  @override
  String get legacyCircleRemoveConfirm => 'Удалить';

  @override
  String get legacyCutoverExplainerTitle => 'Haven обновлён';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Ваша личность и публичный профиль не изменились — вам ничего не нужно с ними делать.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Для большей безопасности ваши круги нужно создать заново, а их участников — пригласить повторно, прежде чем вы снова сможете делиться местоположением в них.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Понятно';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven всё ещё очищает часть данных после недавнего обновления безопасности. Очистка завершится автоматически, как только вы снова окажетесь в сети.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'Панель кругов свёрнута';

  @override
  String get circlesPanelExpandedAnnouncement => 'Панель кругов развёрнута';

  @override
  String get circlesPanelSlightlyOpenAnnouncement => 'Панель кругов приоткрыта';

  @override
  String get circlesPanelHalfOpenAnnouncement =>
      'Панель кругов открыта наполовину';

  @override
  String get circleMemberAnnouncementSelf => 'вы';

  @override
  String get circleMemberAnnouncementFallback => 'участник';

  @override
  String get invitationsRefreshTooltip => 'Обновить приглашения';

  @override
  String get invitationsLoadError => 'Не удалось загрузить приглашения';

  @override
  String get invitationsEmptyTitle => 'Нет приглашений';

  @override
  String get invitationsEmptyMessage =>
      'Когда кто-то пригласит вас в круг, приглашение появится здесь.';

  @override
  String get refreshRingSemanticNoInbox =>
      'Входящие реле не настроены, открывает настройки реле';

  @override
  String refreshRingSemanticChecking(int checked, int total) {
    final intl.NumberFormat checkedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String checkedString = checkedNumberFormat.format(checked);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Проверено $checkedString из $totalString реле';
  }

  @override
  String refreshRingSemanticAllOk(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'Ответили все $totalString реле',
      many: 'Ответили все $totalString реле',
      few: 'Ответили все $totalString реле',
      one: 'Реле ответило',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'Ни одно реле не ответило';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Получен ответ от $okString из $totalString реле';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Проверка реле';

  @override
  String get refreshRingAnnouncementAllOk => 'Все реле ответили';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Получен ответ от $okString из $totalString реле';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'Не удалось связаться ни с одним реле';

  @override
  String get refreshRingAnnouncementNoInbox => 'Входящие реле не настроены';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'Ваши данные есть на всех $totalString реле',
      many: 'Ваши данные есть на всех $totalString реле',
      few: 'Ваши данные есть на всех $totalString реле',
      one: 'Ваши данные есть на реле',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound =>
      'Ваших данных нет ни на одном реле';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Ваши данные есть на $okString из $totalString реле';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'Ваши данные есть на всех реле';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Ваши данные есть на $okString из $totalString реле';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'Ваших данных нет ни на одном реле';

  @override
  String get identityTitle => 'Личность';

  @override
  String get identityLoadError =>
      'Не удалось загрузить вашу личность. Пожалуйста, повторите попытку.';

  @override
  String get identityMissingTitle => 'Нет личности';

  @override
  String get identityMissingMessage =>
      'Ваша личность исчезла. Создайте новую, чтобы продолжить пользоваться Haven.';

  @override
  String get identitySetUpCta => 'Настроить личность';

  @override
  String get identityPublicKeyQrTitle => 'QR публичного ключа';

  @override
  String get identityPublicKeyQrSubtitle => 'Как вас приглашают в круги';

  @override
  String get identityAdvancedTitle => 'Дополнительно';

  @override
  String get identityAdvancedSubtitle =>
      'Публичный ключ, секретный ключ, удаление';

  @override
  String get profileIsPublicNoticeTitle => 'Профиль публичен';

  @override
  String get profileIsPublicNoticeBody =>
      'Ваше отображаемое имя и фото видны любому в сети Nostr, а не только участникам ваших кругов. Делитесь только тем, что готовы сделать публичным.';

  @override
  String get identityRefreshProfileTooltip => 'Обновить публичный профиль';

  @override
  String get identityAdvancedExportError =>
      'Не удалось экспортировать секретный ключ. Пожалуйста, повторите попытку.';

  @override
  String get identityAdvancedDeleteTitle => 'Удалить личность?';

  @override
  String get identityAdvancedDeleteBody =>
      'Это безвозвратно удалит вашу личность. Убедитесь, что вы сохранили резервную копию секретного ключа, если хотите её восстановить.';

  @override
  String get identityAdvancedDeleteConfirm => 'Удалить';

  @override
  String get identityAdvancedDeletedSnack => 'Личность удалена';

  @override
  String get identityAdvancedDeleteError =>
      'Не удалось удалить личность. Пожалуйста, повторите попытку.';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label скопировано в буфер обмена';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Секретный ключ скопирован. Внимание: другие приложения могут читать ваш буфер обмена. Вставьте его в безопасное место и очистите буфер обмена.';

  @override
  String get identityAdvancedMissingBody => 'Личность не настроена.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Публичный ключ';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'Публичный ключ (hex)';

  @override
  String get identityAdvancedCopyValue => 'Публичный ключ';

  @override
  String get identityAdvancedCopyPublicKeyTooltip =>
      'Скопировать публичный ключ';

  @override
  String get identityAdvancedCopyHexTooltip => 'Скопировать hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'Секретный ключ';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Ваш секретный ключ даёт полный доступ к вашей личности. Никогда никому его не сообщайте.';

  @override
  String get identityAdvancedRevealSecretKey => 'Показать секретный ключ';

  @override
  String get identityAdvancedHideSecretKey => 'Скрыть секретный ключ';

  @override
  String get identityAdvancedCopySecretKeyTooltip =>
      'Скопировать секретный ключ';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Удалить личность';

  @override
  String get qrCodeLoadError =>
      'Не удалось загрузить ваш публичный ключ. Пожалуйста, повторите попытку.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Ваш публичный ключ';

  @override
  String get qrCodeWhatIsThisTitle => 'Что это?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven работает на Nostr — открытой сети, за которой нет ни компании, ни аккаунта, ни регистрации. Ваша личность — это всего лишь пара ключей: секретный ключ, который держите только вы, и этот публичный ключ, созданный из него.';

  @override
  String get qrCodeExplainerUsername =>
      'Ваш публичный ключ работает как имя пользователя, которым безопасно делиться. Люди сканируют этот код или вставляют ваш публичный ключ, чтобы пригласить вас в круг. По нему нельзя узнать ни ваше местоположение, которое видно только участникам кругов, в которые вы вступили, ни ваше имя и фото, которые остаются на этом устройстве, пока вы не решите опубликовать публичный профиль.';

  @override
  String get displayNameCardTitle => 'Отображаемое имя';

  @override
  String get displayNameCardLoadError =>
      'Не удалось загрузить ваше отображаемое имя. Повторите попытку позже.';

  @override
  String get displayNameCardHint => 'Введите ваше отображаемое имя';

  @override
  String get displayNameCardSavedLabel => 'Отображаемое имя сохранено';

  @override
  String get displayNameCardSaveLabel => 'Сохранить отображаемое имя';

  @override
  String get displayNameCardSavingLabel => 'Сохраняем отображаемое имя';

  @override
  String get displayNameCardRetryLabel => 'Сохранить не удалось. Повторить';

  @override
  String get displayNameCardSavedAnnouncement => 'Отображаемое имя сохранено';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'Сохранить не удалось, попробуйте снова';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$label скопировано в буфер обмена';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'показан';

  @override
  String get keyDisplayStateHidden => 'скрыт';

  @override
  String get keyDisplayHideTooltip => 'Скрыть';

  @override
  String get keyDisplayRevealTooltip => 'Показать';

  @override
  String get keyDisplayCopyTooltip => 'Скопировать';

  @override
  String get keyDisplayCompactCopied => 'Ключ скопирован в буфер обмена';

  @override
  String get keyDisplayCompactTapToCopy => 'Нажмите, чтобы скопировать';

  @override
  String get npubQrCopiedSnack => 'Публичный ключ скопирован в буфер обмена';

  @override
  String get npubQrCopyButton => 'Скопировать публичный ключ';

  @override
  String get circleMemberPublicKeyCopied =>
      'Публичный ключ скопирован в буфер обмена';

  @override
  String get circleMemberCopyPublicKeyHint => 'Скопировать публичный ключ';

  @override
  String get circleMemberSetNicknameMenuItem => 'Задать псевдоним';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'Скопировать публичный ключ';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'Не удалось обновить профили. Пожалуйста, повторите попытку.';

  @override
  String get memberDetailSheetTitle => 'Сведения об участнике';

  @override
  String get memberNicknameSheetHint => 'Введите псевдоним';

  @override
  String get memberNicknameSheetLabel => 'Псевдоним';

  @override
  String get memberNicknameSheetSave => 'Сохранить псевдоним';

  @override
  String get memberNicknameSheetClear => 'Убрать псевдоним';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Псевдоним сохранён';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Псевдоним убран';

  @override
  String get npubQrScanLabel => 'Отсканируйте, чтобы добавить меня';

  @override
  String get npubQrSemanticsLabel => 'QR-код вашей публичной личности';

  @override
  String get photoHeaderRemoveTitle => 'Удалить фото профиля?';

  @override
  String get photoHeaderRemoveBody =>
      'Это удалит ваше фото из вашего публичного профиля.';

  @override
  String get photoHeaderEditPhoto => 'Изменить фото';

  @override
  String get photoHeaderRemove => 'Удалить';

  @override
  String get photoHeaderViewPhotoSemantics => 'Посмотреть фото профиля';

  @override
  String get photoHeaderAddPhotoSemantics => 'Добавить фото профиля';

  @override
  String get photoHeaderChangePhotoSemantics => 'Изменить фото профиля';

  @override
  String get avatarPickerPhotoUpdated =>
      'Фото обновлено — опубликовано в вашем публичном профиле Nostr.';

  @override
  String get avatarPickerPhotoRemoved => 'Фото удалено.';

  @override
  String get avatarPickerRemoveError =>
      'Не удалось удалить ваше фото. Пожалуйста, повторите попытку.';

  @override
  String get avatarPickerUpdateError =>
      'Не удалось обновить ваше фото. Пожалуйста, повторите попытку.';

  @override
  String get avatarPickerCropTitle => 'Обрезать фото';

  @override
  String get avatarPickerCropDone => 'Готово';

  @override
  String get avatarPickerCropCancel => 'Отмена';

  @override
  String get avatarFullscreenClose => 'Закрыть';

  @override
  String get avatarFullscreenSemantics => 'Фото профиля, во весь экран';

  @override
  String get avatarFullscreenLoadError => 'Не удалось загрузить фото';

  @override
  String get mapInitializing => 'Инициализация...';

  @override
  String get mapInitFailedTitle => 'Не удалось инициализировать';

  @override
  String get mapInitFailedMessage =>
      'Не удалось инициализировать службы геолокации.';

  @override
  String get mapInitFailedRetry =>
      'Инициализация не удалась. Пожалуйста, повторите попытку.';

  @override
  String get mapLocationOffMessage =>
      'Включите местоположение, чтобы видеть себя и свои круги на карте.';

  @override
  String get mapGettingLocation => 'Определяем местоположение...';

  @override
  String get mapLoadingMap => 'Загрузка карты...';

  @override
  String get mapLocationOffTitle => 'Местоположение выключено';

  @override
  String get mapLocationErrorTitle => 'Ошибка местоположения';

  @override
  String get mapLocationUnavailable => 'Местоположение временно недоступно';

  @override
  String get mapThisLocation => 'это место';

  @override
  String get mapMemberFallbackName => 'участник';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return 'Открыть $label в Apple Maps?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'В Apple Maps передаётся только координата на карте, без имени или личности.';

  @override
  String get mapOpenInAppleMapsConfirm => 'Открыть в Apple Maps';

  @override
  String get mapOpenMapsError => 'Не удалось открыть Maps';

  @override
  String get mapControlsZoomIn => 'Приблизить';

  @override
  String get mapControlsZoomOut => 'Отдалить';

  @override
  String get mapControlsRecenter => 'Центрировать';

  @override
  String get mapControlsRecenterFab => 'Центрировать на моём местоположении';

  @override
  String get mapAttributionCreditsButton => 'Авторы карты и лицензия';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'Маркер вашего местоположения$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Точность: $metersString метров';
  }

  @override
  String memberMarkerMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m';
  }

  @override
  String memberMarkerHoursShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h';
  }

  @override
  String memberMarkerDaysShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d';
  }

  @override
  String memberMarkerMinutesAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString минуты назад',
      many: '$countString минут назад',
      few: '$countString минуты назад',
      one: '$countString минуту назад',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerHoursAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString часа назад',
      many: '$countString часов назад',
      few: '$countString часа назад',
      one: '$countString час назад',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerDaysAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString дня назад',
      many: '$countString дней назад',
      few: '$countString дня назад',
      one: '$countString день назад',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'Маркер участника $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'Маркер участника';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, последний раз виден $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name за пределами экрана, направление: $direction; нажмите, чтобы посмотреть';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'Один из участников за пределами экрана, направление: $direction; нажмите, чтобы посмотреть';
  }

  @override
  String get compassNorth => 'север';

  @override
  String get compassNorthEast => 'северо-восток';

  @override
  String get compassEast => 'восток';

  @override
  String get compassSouthEast => 'юго-восток';

  @override
  String get compassSouth => 'юг';

  @override
  String get compassSouthWest => 'юго-запад';

  @override
  String get compassWest => 'запад';

  @override
  String get compassNorthWest => 'северо-запад';

  @override
  String get commonAdd => 'Добавить';

  @override
  String get addRelaySheetTitleInbox => 'Добавить входящее реле';

  @override
  String get addRelaySheetTitleKeyPackage => 'Добавить реле KeyPackage';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Вставить из буфера обмена';

  @override
  String get addRelaySheetErrorEmpty => 'Введите адрес реле.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Используйте wss://, чтобы трафик к этому реле был зашифрован.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'URL реле не должен содержать учётных данных.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'Введите адрес реле в виде wss://relay.example.com.';

  @override
  String get avatarSemanticsLabel => 'Аватар пользователя';

  @override
  String avatarSemanticsFor(String initials) {
    return 'для $initials';
  }

  @override
  String get avatarSemanticsOnline => 'в сети';

  @override
  String get avatarSemanticsOffline => 'не в сети';
}
