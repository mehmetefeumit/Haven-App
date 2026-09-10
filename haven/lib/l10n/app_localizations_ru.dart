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
  String get onboardingValueProp2Title => 'Никто не может его отключить';

  @override
  String get onboardingValueProp3Title => 'Аккаунт не нужен';

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
  String get settingsRelaysTitle => 'Реле';

  @override
  String get settingsLocationTitle => 'Местоположение';

  @override
  String get settingsLocationSubtitleOn => 'Фоновый обмен включён';

  @override
  String get settingsLocationSubtitleOff => 'Только пока Haven открыт';

  @override
  String get settingsMapStyleTitle => 'Стиль карты';

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
  String get locationSettingsBatteryOptNote =>
      'Оптимизация батареи для Haven всё ещё включена. На некоторых телефонах она без предупреждения останавливает фоновый обмен. Исключите Haven, чтобы обмен работал надёжно.';

  @override
  String get locationSettingsErrorSnack => 'Что-то пошло не так';

  @override
  String get locationSettingsIntro =>
      'Haven делится вашим местоположением с вашими кругами всё время, пока приложение открыто. Включите этот параметр — и круги будут видеть его и тогда, когда Haven работает в фоне. Если система закроет Haven, отправка вашего местоположения прекратится: Haven по-прежнему может просыпаться, чтобы получить местоположения ваших кругов, но никогда — чтобы отправить ваше. На Android отправка продолжается, даже если смахнуть Haven из списка недавних приложений, и сама собой возобновляется после перезагрузки телефона. На iPhone отправка не возобновится, пока вы не откроете Haven.';

  @override
  String get locationSettingsToggleTitle => 'Делиться в фоне';

  @override
  String get locationSettingsToggleSubtitle =>
      'Продолжать делиться, пока Haven работает в фоне';

  @override
  String get locationSettingsIosLimitedNote =>
      'Обмен продолжает работать в фоне и при текущем разрешении, и всё это время iOS показывает вверху экрана свою синюю полосу геопозиции. Установите для Haven доступ к геопозиции «Всегда» в Настройках, чтобы он мог получать пропущенные обновления ваших кругов и после того, как iOS закроет приложение. При доступе «Всегда» iOS может показывать в строке состояния свою стрелку геопозиции вместо этой полосы. Ваш собственный обмен возобновится, когда вы снова откроете Haven.';

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
      'Пока фоновый обмен включён, Haven поддерживает сеанс геопозиции, чтобы ваши круги продолжали вас видеть.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'Когда Haven использует ваше местоположение, iOS показывает свою стрелку геопозиции в строке состояния, а затем ещё некоторое время оставляет ту же стрелку рядом с Haven в настройках «Службы геолокации».';

  @override
  String get locationSettingsIosIndicatorBar =>
      'При доступе «Всегда» iOS показывает вверху экрана свою синюю полосу геопозиции, пока Haven использует ваше местоположение.';

  @override
  String get locationDisclosureTitle => 'Обмен вашим местоположением';

  @override
  String get locationDisclosureWhy =>
      'Haven показывает ваше местоположение в реальном времени людям из выбранных вами кругов, а их местоположение показывает вам на карте. Для этого Haven нужно разрешение на доступ к точному местоположению вашего устройства.';

  @override
  String get locationDisclosureHow =>
      'Ваше местоположение сквозно шифруется на вашем устройстве, поэтому прочитать его могут только участники выбранных вами кругов, но не Haven. У Haven нет собственных серверов: ваши зашифрованные обновления проходят через независимые реле, которыми управляют другие люди, — они видят ваш сетевой адрес, но никогда не видят, где вы находитесь. Чтобы отрисовать карту, Haven запрашивает у Stadia Maps участки местности вокруг вас и вашего круга, поэтому Stadia Maps примерно узнаёт, где это, но не узнаёт ни вашего имени, ни вашего ключа, ни того, кто состоит в ваших кругах. Stadia Maps заявляет, что не продаёт и не обменивает персональные данные, не устанавливает cookie на вашем устройстве и хранит серверные журналы около двух недель. Это их собственная политика, и Haven не может обеспечить её соблюдение.';

  @override
  String get locationDisclosureSharing =>
      'Пока Haven открыт и вы состоите в круге, ваше местоположение отправляется автоматически каждые несколько минут. Приостановить обмен нельзя. Чтобы перестать делиться с кругом, покиньте его.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'Это приложение использует данные о местоположении, чтобы обмен с вашими кругами работал, даже когда приложение закрыто или не используется.';

  @override
  String get locationDisclosureBackgroundIos =>
      'Это приложение использует данные о местоположении, чтобы обмен с вашими кругами работал, даже когда Haven находится в фоне и вы им не пользуетесь. Если iOS закроет Haven, обмен прекратится, пока вы не откроете его снова: Haven по-прежнему может просыпаться, чтобы получить местоположения ваших кругов, но никогда — чтобы отправить ваше.';

  @override
  String get locationDisclosureManage =>
      'Фоновый обмен можно в любой момент отключить в разделе Настройки → Местоположение.';

  @override
  String get locationDisclosureAgree => 'Согласиться';

  @override
  String get locationDisclosureNotNow => 'Не сейчас';

  @override
  String get fgsNotificationSharing =>
      'Haven отправляет и получает данные о местоположении';

  @override
  String get fgsNotificationPaused =>
      'Haven приостановлен — откройте приложение, чтобы возобновить обмен';

  @override
  String get fgsNotificationOpen => 'Haven открыт на экране';

  @override
  String get fgsChannelName => 'Обмен местоположением';

  @override
  String get fgsChannelDescription =>
      'Поддерживает обмен вашим зашифрованным местоположением, пока Haven работает в фоне.';

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
  String get aboutFooterLicense => 'Распространяется под лицензией MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Версия $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'У Haven нет собственного сервера. Ваши зашифрованные обновления проходят через независимые серверы, которые называют реле: они не могут прочитать ни ваше местоположение, ни ваши сообщения.';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Круг «$name» создан. Приглашения отправлены ($sentString из $totalString); доставка остальных ожидается.';
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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Число кругов, в которых вы можете состоять одновременно: $limitString. Покиньте один из кругов, чтобы освободить место для нового.';
  }

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
  String get circleMemberNoRecentLocation => 'Нет недавнего местоположения';

  @override
  String get circleMemberRemoveTooltip => 'Удалить из круга';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return 'Удалить участника $name из круга?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'Читать новое в этом круге этот человек перестанет, как только остальные участники получат обновление: обычно на это уходит несколько минут, а для тех, кто в этот момент был не в сети, дольше. То, что он уже получил, останется на его телефоне. Чтобы это отменить, придётся пригласить человека заново.';

  @override
  String get circleMemberRemoveConfirm => 'Удалить';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'Удаляем участника $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name больше не в круге';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'Не удалось удалить участника $name. Ничего не изменилось — проверьте соединение и попробуйте снова.';
  }

  @override
  String get circleMemberAdmin => 'Админ';

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
  String get memberPickerSectionRoster => 'Участники ваших кругов';

  @override
  String get memberPickerTierRoster => 'Состоит в ваших кругах';

  @override
  String get memberPickerNoMatches => 'В ваших кругах совпадений нет';

  @override
  String get memberPickerLoading => 'Читаем списки участников ваших кругов';

  @override
  String get memberPickerDirectoryUnavailable =>
      'Сейчас не удалось прочитать списки участников ваших кругов';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Совпадений: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'Это ваш собственный ID';

  @override
  String get memberPickerReadPublicKey => 'Озвучить публичный ключ';

  @override
  String get memberPickerSectionRecent => 'Недавно в ваших кругах';

  @override
  String get memberPickerTierRecent => 'Недавно в ваших кругах';

  @override
  String get memberPickerNicknameNote =>
      'Ваш псевдоним для этого человека, а не его публичное имя';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'В круге «$circleName»';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven запросил у одного реле опубликованное имя этого человека. Реле видит, что это устройство только что спросило об этом ключе, но запрос не подписан, поэтому не связан с вашей личностью в Haven. Фото пока не скачано.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+ещё $countString';
  }

  @override
  String get invitationCardHeading => 'Приглашение в круг';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Приглашение вступить в круг. Вас приглашает $inviter';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Приглашает криптографический идентификатор $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Приглашает: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'Ваш псевдоним для этого человека, а не его публичное имя';

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
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Число кругов, в которых вы можете состоять одновременно: $limitString. Покиньте один из кругов, и тогда вы сможете принять это приглашение.';
  }

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
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · срок $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString мин',
      many: '$countString мин',
      few: '$countString мин',
      one: '$countString мин',
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
      other: '$countString сек',
      many: '$countString сек',
      few: '$countString сек',
      one: '$countString сек',
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
      other: 'примерно через $countString минуты',
      many: 'примерно через $countString минут',
      few: 'примерно через $countString минуты',
      one: 'примерно через $countString минуту',
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
      other: 'через $countString секунды',
      many: 'через $countString секунд',
      few: 'через $countString секунды',
      one: 'через $countString секунду',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven просит реле $expiry удалять обновления местоположения, которые вы отправляете в этот круг.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Реле для этого круга';

  @override
  String get circleDetailsNoRelays => '(не указаны)';

  @override
  String get circleDetailsRelaysNote =>
      'Эти реле взяты из списков, опубликованных приглашёнными участниками; если у этих участников списков не было — из ваших входящих реле или из тех, что выбрал Haven. Изменить их пока нельзя, а последующие правки вашего списка реле на них не влияют.';

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
      'Это удалит с этого телефона вашу личность и все данные кругов. Всё, что уже опубликовано под ней, останется на своих местах: имя и ключи — на тех реле, где они есть, а фотография — на хостинге изображений, где она хранится. Убедитесь, что вы сохранили резервную копию секретного ключа, если хотите восстановить личность.';

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
  String get profileSyncStatusSyncing =>
      'Синхронизируем с вашим публичным профилем…';

  @override
  String get profileSyncStatusPartial =>
      'Опубликовано — часть реле ещё синхронизируется';

  @override
  String get profileSyncStatusSynced => 'Публичный профиль актуален';

  @override
  String get profileSyncStatusFailed => 'Пока не удалось синхронизировать.';

  @override
  String get profileSyncStatusRetrySemantics =>
      'Повторить публикацию вашего профиля';

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
      'Фото обновлено. Будет опубликовано в вашем публичном профиле Nostr.';

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
  String get mapLocationNoPermissionTitle =>
      'У Haven нет доступа к местоположению';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'На этом устройстве выключено местоположение, поэтому Haven перестал делиться им с вашими кругами. Включите местоположение, чтобы возобновить обмен.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven больше не может использовать ваше местоположение, поэтому перестал делиться им с вашими кругами. Разрешите доступ, чтобы возобновить обмен.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'В системных настройках у Haven отключён доступ к местоположению, поэтому обмен прекратился. Разрешите доступ там, чтобы возобновить его.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven перестал делиться вашим местоположением. Включите местоположение на этом устройстве и разрешите Haven доступ к нему.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven перестал получать ваше местоположение, поэтому обмен прекратился. Проверьте, включено ли местоположение и разрешён ли Haven доступ к нему.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Доступ к местоположению восстановлен. Haven снова делится им с вашими кругами.';

  @override
  String get clockSkewTitle => 'Часы этого телефона идут неверно';

  @override
  String get clockSkewBodyRejected =>
      'Ваши круги не получают ваше местоположение: реле отклоняют метку времени, которую ставит этот телефон. Включите в системных настройках автоматическую установку даты и времени, чтобы это исправить.';

  @override
  String get clockSkewBodyBehind =>
      'Этот телефон отстаёт по времени от остальных участников ваших кругов: местоположение отправляется, но срок его жизни истекает раньше, чем его успевают увидеть. Включите в системных настройках автоматическую установку даты и времени, чтобы это исправить.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'Проблема с часами устранена. Haven снова делится вашим местоположением.';

  @override
  String get clockSkewTitleDisagreement =>
      'В одном из ваших кругов чьи-то часы идут неверно';

  @override
  String get clockSkewBodyDisagreement =>
      'Часы этого телефона и часы другого участника расходятся на две минуты или больше. Если неверно идут часы именно этого телефона, у местоположений, которые он отправляет, срок жизни может истечь раньше, чем их успеют увидеть. Включите в системных настройках автоматическую установку даты и времени, чтобы убедиться, что дело не в этом телефоне.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'Предупреждение о часах исчезло.';

  @override
  String get sharingHealthTitleStopped => 'Обмен местоположением прекратился';

  @override
  String get sharingHealthTitleNotSending =>
      'Ваше местоположение не отправляется';

  @override
  String get sharingHealthTitleNotReceiving =>
      'Вы не получаете местоположения участников';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Нет обновлений уже примерно $countString минуты',
      many: 'Нет обновлений уже примерно $countString минут',
      few: 'Нет обновлений уже примерно $countString минуты',
      one: 'Нет обновлений уже примерно $countString минуту',
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
      other: 'Нет обновлений уже примерно $countString часа',
      many: 'Нет обновлений уже примерно $countString часов',
      few: 'Нет обновлений уже примерно $countString часа',
      one: 'Нет обновлений уже примерно $countString час',
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
      other: 'Нет обновлений уже примерно $countString дня',
      many: 'Нет обновлений уже примерно $countString дней',
      few: 'Нет обновлений уже примерно $countString дня',
      one: 'Нет обновлений уже примерно $countString день',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Исправить';

  @override
  String get sharingHealthRepairUnavailableHint =>
      'Кнопка «Исправить» недоступна для этого круга';

  @override
  String get sharingHealthRepairHint =>
      'Переподключается к реле, повторяет отправку вашего местоположения и, если вы админ этого круга, может выдать ему новый ключ';

  @override
  String get sharingHealthRepairSent =>
      'Исправление отправлено. Остальные участники подхватят его, когда оно дойдёт до их телефонов.';

  @override
  String get sharingHealthRepairNotOwner =>
      'Исправить этот круг может только его админ. Попросите админа удалить вас и добавить снова.';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'Этот круг нельзя исправить на этом телефоне. Создайте новый круг с теми же людьми.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Сейчас исправлять нечего. Haven продолжит попытки.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'Обмен местоположением всё ещё не работает.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'Обмен местоположением снова работает.';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Последнее местоположение: $countString минуты назад',
      many: 'Последнее местоположение: $countString минут назад',
      few: 'Последнее местоположение: $countString минуты назад',
      one: 'Последнее местоположение: $countString минуту назад',
    );
    return '$_temp0';
  }

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
