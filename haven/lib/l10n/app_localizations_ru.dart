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
      'У Haven нет центрального сервера. Ваши зашифрованные сообщения идут через независимые серверы, которые называют реле, и вы сами выбираете, какими из них пользоваться. Ни одна компания и ни одно государство не могут отключить эту сеть.';

  @override
  String get onboardingValueProp3Title => 'Аккаунт не нужен';

  @override
  String get onboardingValueProp3Body =>
      'Никакой почты, телефона или регистрации. Haven создаёт личность, секретный ключ которой никогда не покидает ваш телефон, поэтому нет и аккаунта, который кто-либо мог бы передать третьим лицам.';

  @override
  String get onboardingValueProp1Summary =>
      'Шифруется на устройстве — прочитают только выбранные вами круги.';

  @override
  String get onboardingValueProp2Summary =>
      'Без центрального сервера. Работает через сеть реле, которую выбираете вы.';

  @override
  String get onboardingValueProp3Summary =>
      'Ни почты, ни телефона, ни регистрации. Секретный ключ никогда не покидает ваш телефон.';

  @override
  String get onboardingCreateIdentityTitle => 'Создайте свою личность';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven создаёт ваши ключи прямо на этом телефоне. Секретный ключ никогда его не покидает.';

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
  String get onboardingAddPhotoOptional => 'Добавить фото (необязательно)';

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
      'kind 10050: сюда приходят приглашения для вас';

  @override
  String get relaySettingsKeyPackageTitle => 'Мои реле KeyPackage';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10002: здесь другие находят ключи, которые нужны, чтобы вас пригласить';

  @override
  String get relaySettingsProfileTitle => 'Мои реле профиля';

  @override
  String get relaySettingsProfileSubtitle =>
      'kind 0: здесь ищут и публикуют ваш публичный профиль. Эти реле отделены от остальных ваших реле, а сам список реле профиля никогда не публикуется';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'Запросы профилей приостановлены';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'Осталось слишком мало реле профиля, поэтому имена и фото участников перестанут обновляться.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Восстановить реле профиля по умолчанию';

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
  String get relaySettingsProfileContaminationTooltip =>
      'Через это реле идёт и другой трафик Haven';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Предупреждение: через $url идёт и другой ваш трафик Haven, поэтому это реле может связать ваш профиль с этим трафиком';
  }

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
      'Haven делится вашим местоположением с вашими кругами всё время, пока приложение открыто. Включите этот параметр, и круги будут видеть его и тогда, когда Haven работает в фоне; а если система закроет Haven, обновления возобновятся, когда вы начнёте двигаться или когда система в следующий раз разбудит приложение.';

  @override
  String get locationSettingsToggleTitle => 'Делиться в фоне';

  @override
  String get locationSettingsToggleSubtitle =>
      'Продолжать делиться при закрытом приложении';

  @override
  String get locationSettingsIosLimitedNote =>
      'Обмен продолжает работать в фоне и при текущем разрешении. Установите для Haven доступ к геопозиции «Всегда» в Настройках, чтобы обновления могли возобновляться и после того, как iOS закроет приложение.';

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
      'Пока фоновый обмен включён, Haven поддерживает непрерывный сеанс геопозиции, а iOS показывает синий индикатор в строке состояния. Доступ «Всегда» дополнительно позволяет Haven получать пропущенные обновления ваших кругов после того, как iOS закроет приложение.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Распространяется под лицензией MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Версия $version';
  }

  @override
  String get privacyTitle => 'Приватность';

  @override
  String get privacySubtitle => 'Как работает Haven и что видят другие';

  @override
  String get privacyHubSummary =>
      'Haven делится вашим местоположением только с небольшими группами, которые вы выбираете сами; такие группы называются кругами. Местоположение шифруется на телефоне ещё до отправки. Здесь нет ни регистрации, ни сервера Haven. Публично только одно: отображаемое имя и фото, которые вы задали. Страницы ниже простым языком объясняют и это, и всё остальное.';

  @override
  String get privacyGroupBasicsHeading => 'Основное';

  @override
  String get privacyMeansForYouLabel => 'Что это значит для вас';

  @override
  String get privacyMoreDetailLabel => 'Подробнее';

  @override
  String get privacyMoreDetailExpandHint => 'Показать технические подробности';

  @override
  String get privacyMoreDetailCollapseHint => 'Скрыть технические подробности';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'Технические подробности показаны';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Технические подробности скрыты';

  @override
  String get privacyWhatHavenIsTitle =>
      'Что такое Haven и почему здесь нет аккаунта';

  @override
  String get privacyWhatHavenIsSubtitle =>
      'Без регистрации, без корпоративного сервера';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven делится вашим местоположением с небольшими группами по вашему выбору — они называются кругами. За этим не стоит никакой аккаунт. Вы не указываете ни почту, ни телефон, ни пароль.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'У Haven также нет собственных серверов. Ваши зашифрованные обновления местоположения проходят через независимые серверы, которые называют реле, и держат их другие люди. Разработчики Haven не видят ваше местоположение и не встроили в приложение никакой слежки. Они видят только одно: общее количество обращений к карте. Плитки карты запрашиваются с одним общим ключом, поэтому кто именно их запросил, остаётся неизвестным.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'Никого нельзя заставить выдать ваши данные, потому что их никто не хранит. Обратная сторона в том, что и восстановить вашу личность за вас никто не сможет. Что именно стоит сохранить, описано в разделе «Ваши два ключа».';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'В приложении нет ни аналитики, ни отчётов о сбоях, ни рекламного кода. А поскольку Haven имеет открытый исходный код, это можно проверить, а не принимать на веру.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'У Haven также нет push-уведомлений — и это сделано намеренно. Службу уведомлений пришлось бы извещать каждый раз, когда кто-то из ваших кругов отправляет вам что-нибудь, а это раскрывало бы больше о ваших привычках, чем реле.';

  @override
  String get privacyYourKeysTitle =>
      'Ваши два ключа: секретный храните, публичным делитесь';

  @override
  String get privacyYourKeysSubtitle =>
      'Что подтверждает вашу личность и что стоит сохранить';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'Вместо имени пользователя и пароля у вас есть пара ключей. Секретный ключ подтверждает, что вы — это вы. Публичный ключ нужен другим, чтобы найти вас и пригласить.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Ваш секретный ключ хранится только на этом телефоне, в хранилище, которое защищает операционная система. Haven никуда его не отправляет: ни на какой сервер, ни нам.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Публичным ключом можно безопасно делиться. Он работает как имя пользователя, которое можно опубликовать где угодно. По нему нельзя узнать, где вы находитесь.';

  @override
  String get privacyYourKeysMeansForYou =>
      'Чтобы сохранить эту личность, сделайте резервную копию. Откройте Настройки → Личность → Дополнительно, нажмите «Показать секретный ключ» и сохраните его в надёжном месте, например в менеджере паролей. Без такой копии потеря телефона означает потерю личности навсегда.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Любой, кто получит ваш секретный ключ, станет вами. Он сможет вступать в круги от вашего имени и публиковать под вашим именем. Никогда не вставляйте его в другое приложение, в сообщение или на сайт.';

  @override
  String get privacyYourKeysDetailFormats =>
      'Оба ключа основаны на secp256k1 и показаны в стандартных форматах Nostr: npub1… для публичного ключа и nsec1… для секретного. Подпись создаётся внутри приложения, а секретный ключ очищается там, где с ним работают напрямую, сразу после использования.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'Ключи, которыми шифруются сообщения в ваших кругах, отделены от этого ключа личности и хранятся только в приложении. Это разделение сделано намеренно: ключ, который вас называет, — не тот ключ, который открывает отправленное вами.';

  @override
  String get privacyPublicProfileTitle => 'Ваше имя и фото публичны';

  @override
  String get privacyPublicProfileSubtitle =>
      'Видны любому, а не только вашим кругам';

  @override
  String get privacyPublicProfileIsPublic =>
      'Отображаемое имя и фото, которые вы задаёте, публикуются в Nostr, открытой публичной сети, на которой работает Haven. Найти их может кто угодно, а не только участники ваших кругов.';

  @override
  String get privacyPublicProfileOnSave =>
      'Ваши имя и фото становятся публичными в тот же момент, когда вы их сохраняете. Нет настройки, которая оставила бы их приватными, и нет способа показать имя только своим кругам.';

  @override
  String get privacyPublicProfilePseudonym =>
      'При новой установке приложение сразу выдаёт вымышленное имя, например «Quiet Wanderer», которое ничего о вас не говорит. Его можно оставить или заменить на любое другое.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Выбирайте имя и фото, которые не жаль показать всем. Если не хотите, чтобы вас узнавали, оставьте выданное вымышленное имя и не добавляйте фото.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Если позже убрать фото, копия на сервере не удаляется. Haven заменяет ваш профиль пустым. Файл изображения остаётся там, где он размещён, а любая уже скачанная копия остаётся у того, кто её скачал. Считайте, что всё опубликованное останется навсегда.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'Профиль представляет собой событие Nostr «kind 0», подписанное вашим ключом личности. Фотографии загружаются на публичный хостинг изображений blossom.primal.net, который видит изображение, ваш публичный ключ и ваш сетевой адрес. Выбрать другой хостинг Haven пока не позволяет.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Перед загрузкой Haven перекодирует снимок и убирает скрытые данные, которые добавляют камеры, включая GPS-координаты места съёмки. Здесь это важно: иначе фото из отпуска может содержать координаты вашего дома.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'Как передаётся ваше местоположение';

  @override
  String get privacyRelaysTitle =>
      'Реле: серверы, которые передают сообщения дальше';

  @override
  String get privacyRelaysSubtitle =>
      'Через чьи компьютеры проходят ваши обновления';

  @override
  String get privacyRelaysWhatIsARelay =>
      'У Haven нет собственного сервера, поэтому ваши обновления идут через серверы других людей. Такие серверы называют реле: небольшие и независимые, запустить их может кто угодно. Реле недолго хранит зашифрованное сообщение, а потом передаёт его дальше по запросу вашего круга.';

  @override
  String get privacyRelaysWhyMany =>
      'Haven использует несколько реле, поэтому ни одно из них не может отрезать вас от связи. Если одно отключится, остальные продолжат работать. Реле, на которые приходят приглашения, выбираете вы; реле, которыми пользуется круг, задаются при его создании.';

  @override
  String get privacyRelaysYourLists =>
      'Haven ведёт для вас три списка. На ваши входящие реле приходят приглашения, а с ваших реле KeyPackage другие берут ключи, которые нужны, чтобы вас пригласить, — оба этих списка Haven публикует, чтобы их можно было найти. С реле профиля всё иначе: на них ищут и публикуют ваше имя и фото, но сам список остаётся на вашем устройстве и никогда не публикуется. Поэтому у реле, через которое идёт только ваш трафик местоположения или приглашения, нет публичного списка, который подсказал бы ему, какими реле вы пользуетесь для профиля. У каждого круга есть ещё и свой список, и именно по нему идут зашифрованные обновления этого круга.';

  @override
  String get privacyRelaysMeansForYou =>
      'Реле никогда не видит ваше местоположение: оно зашифровано ещё до того, как покидает телефон. Зато реле видит то, что должно быть публичным, чтобы вас могли найти: ваше имя и фото, ключи, которые нужны другим для приглашения, и сам ваш список реле. Haven сразу выдаёт вам рабочие реле, поэтому менять ничего не нужно.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Помимо ваших собственных списков, Haven обращается к небольшому набору публичных справочных реле, чтобы находить чужие профили и ключи. Он делает это, даже если у вас настроены только свои приватные реле. Эти реле видят ваш сетевой адрес и то, какие аккаунты вы искали.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'Ваш список реле KeyPackage подписан вашим ключом личности и публикуется на тех реле, которые уже есть в этом списке. Если добавить туда приватное реле, его адрес станет публичным и будет связан с вами. Оставить приватным реле из этого списка невозможно.';

  @override
  String get privacyEncryptionTitle => 'Как работает шифрование';

  @override
  String get privacyEncryptionSubtitle =>
      'У каждого круга свой ключ; что меняется, когда кто-то входит или уходит';

  @override
  String get privacyEncryptionPerCircle =>
      'Ваше местоположение шифруется на телефоне ещё до отправки, по открытому стандарту MLS. Каждый круг представляет собой отдельную зашифрованную группу со своими ключами. Никто за пределами круга не может прочитать то, что отправлено внутри него: ни реле, ни Haven, ни другой круг, в котором вы состоите.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'Когда кто-то присоединяется, круг переходит на новый ключ. Новый участник может читать то, что отправлено после его прихода, и ничего из отправленного раньше. Haven никогда не отправляет новому участнику прошлые местоположения.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'Когда кто-то покидает круг, круг переходит на очередной новый ключ. Читать новое этот человек перестаёт, как только остальные участники получат обновление: обычно на это уходит несколько минут, а для тех, кто в этот момент был не в сети, дольше.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Уход из круга не отменяет того, что его участники уже сохранили. Haven меняет ключи только тогда, когда кто-то присоединяется или уходит, и никогда не делает этого по расписанию. Поэтому один ключ может покрывать недели сообщений, и всё, что участник сохранил за это время, остаётся ему доступным. Но открыть отправленное после его ухода он всё равно не сможет.';

  @override
  String get privacyEncryptionMeansForYou =>
      'Шифрование защищает вас от всех, кто находится вне ваших кругов. От того, кто когда-то был внутри, оно не защитит. Чтобы перестать делиться местоположением с конкретным человеком, покиньте круг, в котором вы с ним состоите, и создайте новый без него.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) — тот же стандарт IETF, который используют другие защищённые мессенджеры. С сетью Nostr Haven работает через протокол Marmot: он описывает, как группы MLS передаются через реле. Ключ, которым подписываются сообщения каждого круга, отделён от вашего публичного ключа личности Nostr.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Каждый период действия ключа называется эпохой, и круг переходит к новой эпохе только при изменении состава. Ваше устройство хранит ключи текущей эпохи и нескольких недавних, чтобы открыть сообщения, которые ещё идут, а остальные удаляет. Круг, состав которого не менялся месяцами, до сих пор находится в той эпохе, с которой начинал.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'Что видят участники и что видят реле';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'Люди, с которыми вы делитесь, и серверы между вами';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'Люди в ваших кругах';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Все в круге видят на карте ваше точное местоположение, а не примерную область. Нет настройки, которая показывала бы одним участникам приблизительное местоположение, а другим — точное.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Пока Haven открыт и вы состоите в круге, ваше местоположение отправляется само каждые пару минут. Кнопки паузы нет: переключатель на странице «Местоположение» решает только то, продолжится ли отправка после закрытия приложения. Чтобы перестать делиться с кругом, откройте его и выберите «Покинуть круг».';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Вступая в круг, вы также открываете всем его участникам свой публичный ключ. По нему они могут найти ваш публичный профиль и всё остальное, что вы когда-либо публиковали под этим ключом.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Ваш телефон сам скачивает фото профиля каждого участника с сервера, который выбрал этот участник, без единого нажатия с вашей стороны. После этого сервер видит ваш сетевой адрес, а по нему вас можно примерно поместить на карту. Скрыть это может только VPN, больше ничто.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'Операторы реле';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Реле, независимые серверы на пути ваших обновлений, не могут прочитать ни ваше местоположение, ни ваши сообщения, ни название круга, ни список его участников. Обновления местоположения уходят с нового одноразового адреса отправителя, а не с вашего публичного ключа. Профиль, приглашения и списки реле идут с ним, поэтому реле, которое обрабатывает и то и другое, часто может понять, что вы состоите в круге, не читая ничего внутри.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'Зато они видят ваш сетевой адрес, время, когда вы в сети, а также размер и частоту вашего трафика. У каждого круга есть случайная метка. По этой метке реле может собрать сообщения одного круга вместе и оценить, сколько в нём людей, не узнавая при этом, кто именно.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Вступайте в круг только с теми, кому дали бы свой домашний адрес. От реле и посторонних шифрование защищает, а VPN скрывает сетевой адрес, с которого подключается ваш телефон. От участника, который сделает снимок экрана, не защищает ничто.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'Метка круга остаётся неизменной всё время его существования, поэтому реле может сколько угодно долго связывать между собой все его сообщения. Это свойство самого протокола, и Haven не может его изменить.';

  @override
  String get commonLearnMore => 'Узнать больше';

  @override
  String get relaySettingsBackendCaption =>
      'У Haven нет собственного сервера. Ваши зашифрованные обновления проходят через независимые серверы, которые называют реле: они не могут прочитать ни ваше местоположение, ни ваши сообщения.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'Здесь всё зависит от вашего телефона. На Android Haven блокирует снимки экрана и запись экрана во всём приложении. На iPhone он так не может: Haven размывает предпросмотр в переключателе приложений, но участник всё равно может снять то, что видно на экране.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven просит реле удалять сообщения с местоположением примерно через четыре минуты. Это только просьба: реле вправе хранить их дольше. У приглашений срока жизни нет вовсе, и они могут лежать на вашем входящем реле неограниченно долго.';

  @override
  String get privacyGroupTheLimitsHeading => 'Ограничения';

  @override
  String get privacyInferenceTitle => 'Что о вас всё равно можно узнать';

  @override
  String get privacyInferenceSubtitle =>
      'Следы, которые шифрование не скрывает';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'Шифрование скрывает то, что вы отправляете. Оно не может скрыть сам факт отправки. Оставшийся след называется метаданными: когда ушло сообщение, какого оно было размера и к каким серверам вы подключались. Всё это остаётся видимым, даже когда содержимое скрыто.';

  @override
  String get privacyInferenceActivityPattern =>
      'По этой картине реле, которым вы пользуетесь, может примерно определить, когда и как часто вы активны. Haven отправляет ещё и дополнительное обновление каждый раз, когда вы отходите примерно на сотню метров. За несколько часов это может показать реле, были ли вы в пути или оставались на месте. Где именно, оно не показывает никогда.';

  @override
  String get privacyInferencePresence =>
      'Пока Haven работает, он держит открытое соединение с вашими реле. Они видят, что вы в сети, и то, за метками каких кругов вы следите, но никогда не видят ни названия круга, ни его состава. Это цена того, что обновления приходят за секунды, а не за минуты.';

  @override
  String get privacyInferenceIpHeading => 'Ваш сетевой адрес';

  @override
  String get privacyInferenceIpAddress =>
      'Каждый сервер, с которым связывается Haven, видит адрес, с которого подключается ваш телефон, его IP-адрес: это ваши реле, поставщик карт и тот, кто размещает фото профиля участника. Ваш интернет-провайдер видит, к каким из этих серверов вы обращались и когда. Сам по себе Haven не скрывает ни того, ни другого.';

  @override
  String get privacyInferenceMapTilesHeading => 'Сама карта';

  @override
  String get privacyInferenceMapTiles =>
      'Чтобы нарисовать карту, Haven запрашивает у поставщика карт квадраты изображения, которые видны на экране, — так он примерно узнаёт, какие места вы рассматриваете. Ещё Haven заранее подгружает небольшую область вокруг каждого участника, которого вы видите, чтобы карта была готова до того, как вы туда прокрутите. А значит, поставщик может примерно понять, где находятся люди из вашего круга, а не только куда смотрите вы. Эти квадраты хранятся в зашифрованном кэше на вашем телефоне не дольше семи дней. Если вы удалите свою личность, они будут стёрты вместе с ней.';

  @override
  String get privacyInferenceVpnHeading => 'Стоит ли использовать VPN?';

  @override
  String get privacyInferenceVpnHelps =>
      'VPN подменяет ваш адрес своим, поэтому реле и остальные серверы больше не видят, откуда вы подключаетесь. Он также скрывает от вашего интернет-провайдера, к каким серверам вы обращаетесь. Мы рекомендуем Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'Это не панацея. VPN ничего не меняет в том, что видят участники ваших кругов, и не скрывает от реле, с которым вы общаетесь, время и размер вашего трафика. А ещё он переносит ваше доверие на поставщика VPN, а не избавляет вас от необходимости кому-то доверять.';

  @override
  String get privacyInferenceMeansForYou =>
      'Беспокоят реле, ваш интернет-провайдер или серверы карт, которые могут поместить вас на карту? Тогда VPN станет самым полезным, что вы можете добавить. Беспокоят люди в ваших кругах? Он не поможет совсем.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven намеренно меняет интервал между обновлениями, поэтому на короткой записи не видно ровного ритма. Но в среднем за много часов исходную частоту всё же можно оценить. Сообщения к тому же не дополняются до одинакового размера, а обновления местоположения попадают в узкий диапазон размеров — по нему их можно распознать именно как обновления местоположения.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Две вещи лежат за пределами любых решений в самом приложении: наблюдатель, способный следить сразу за многими реле, и ваш собственный телефон, попавший под чужой контроль.';

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
  String get createCircleNoAccountFound =>
      'Не удалось найти аккаунт Haven по этому идентификатору';

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
      'Все в этом круге видят местоположение друг друга, а также публичное имя и фото друг друга. Ваши имя и фото публичны в сети Nostr, они не остаются приватными внутри этого круга. Этот круг остаётся отдельным от любых других, в которых вы состоите, поэтому его участники не видят ни ваших других кругов, ни их состава.';

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
      'Как только человек примет приглашение, он будет видеть местоположение всех участников с этого момента и никогда не увидит ничего отправленного до его вступления. Он также увидит публичные ключи всех, кто уже состоит в этом круге.';

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
  String get pendingMemberRemoveTooltip => 'Убрать из списка';

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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · эпоха $epochString';
  }

  @override
  String get circleDetailsRelaysHeading => 'Реле для этого круга';

  @override
  String get circleDetailsNoRelays => '(не указаны)';

  @override
  String get circleDetailsRelaysNote =>
      'Эти реле были скопированы из ваших входящих реле при создании круга, и изменить их пока нельзя. Изменения, которые вы позже внесёте в свой личный список реле, на них не влияют.';

  @override
  String get circleDetailsAddMember => 'Добавить участника';

  @override
  String get circleDetailsLeaveCircle => 'Покинуть круг';

  @override
  String get leaveCircleDialogTitle => 'Покинуть круг';

  @override
  String get leaveCircleDialogBody =>
      'Покинуть этот круг? Вы перестанете отправлять своё местоположение его участникам и перестанете видеть их местоположение. Последняя отправленная вами точка останется на их телефонах до суток. Отменить это нельзя: чтобы вернуться, вам понадобится новое приглашение.';

  @override
  String get leaveCircleConfirm => 'Покинуть';

  @override
  String get leaveCircleIdentityUnavailable => 'Личность недоступна';

  @override
  String get leaveCircleSuccess => 'Вы покинули круг';

  @override
  String get leaveCircleError => 'Не удалось покинуть круг';

  @override
  String get circleBlockedBannerTitle => 'Этот круг нельзя обновить';

  @override
  String get circleBlockedBannerBody =>
      'Что-то пошло не так с шифрованием этого круга, поэтому Haven больше не может отправлять и получать в нём обновления. Ниже по-прежнему доступно последнее известное состояние, или вы можете покинуть круг.';

  @override
  String get legacyCircleBannerTitle => 'Этот круг нужно создать заново';

  @override
  String get legacyCircleBannerBody =>
      'Механизм шифрования Haven был обновлён, поэтому этот круг больше нельзя использовать. Создайте его заново, чтобы продолжить делиться местоположением с теми же людьми. Вам нужно будет пригласить их снова.';

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
      'Ваша личность и публичный профиль не изменились. Ничего делать с ними не нужно.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Для большей безопасности ваши круги нужно создать заново, а их участников — пригласить повторно, прежде чем вы снова сможете делиться местоположением в них.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Понятно';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven всё ещё просит реле удалить часть старых данных, оставшихся после недавнего обновления безопасности.';

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
      'Это удалит с этого телефона вашу личность и все данные кругов. Всё, что уже опубликовано под ней, включая ваше имя, фото и ключи, останется на тех реле, где оно есть. Убедитесь, что вы сохранили резервную копию секретного ключа, если хотите восстановить личность.';

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
      'Ваш публичный ключ работает как имя пользователя, которым безопасно делиться. Люди сканируют этот код или вставляют ваш публичный ключ, чтобы пригласить вас в круг. По нему нельзя узнать, где вы находитесь. Ваше отображаемое имя и фото и так публичны, поэтому этот код ничего к ним не добавляет.';

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
      'Это уберёт ваше фото из вашего публичного профиля. Файл изображения останется на сервере, который его размещает, а копии, которые уже скачали другие, останутся у них.';

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
      'Фото обновлено. Опубликовано в вашем публичном профиле Nostr.';

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
  String get addRelaySheetTitleProfile => 'Добавить реле профиля';

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
