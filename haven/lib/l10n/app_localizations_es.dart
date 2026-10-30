// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appearanceTitle => 'Apariencia';

  @override
  String get appearanceThemeHeader => 'Tema';

  @override
  String get appearanceThemeSystem => 'Predeterminado del sistema';

  @override
  String get appearanceThemeSystemSubtitle =>
      'Coincidir con la configuración de tu dispositivo';

  @override
  String get appearanceThemeLight => 'Claro';

  @override
  String get appearanceThemeLightSubtitle => 'Usar siempre el tema claro';

  @override
  String get appearanceThemeDark => 'Oscuro';

  @override
  String get appearanceThemeDarkSubtitle => 'Usar siempre el tema oscuro';

  @override
  String get appearanceLanguageTitle => 'Idioma';

  @override
  String get languageSystemDefault => 'Predeterminado del sistema';

  @override
  String get commonTryAgain => 'Reintentar';

  @override
  String get commonDismiss => 'Descartar';

  @override
  String get commonSettings => 'Ajustes';

  @override
  String get commonInvitations => 'Invitaciones';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString invitaciones pendientes',
      many: '$countString invitaciones pendientes',
      one: '$countString invitación pendiente',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Atrás';

  @override
  String get commonContinue => 'Continuar';

  @override
  String get commonSkip => 'Omitir';

  @override
  String get commonRetry => 'Reintentar';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Paso $currentString de $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Comparte tu ubicación de forma privada, solo con quienes tú quieras.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'solo';

  @override
  String get onboardingWelcomeCta => 'Empezar';

  @override
  String get onboardingValuePropsTitle => 'Qué hace diferente a Haven';

  @override
  String get onboardingValueProp1Title => 'Solo tus círculos pueden verte';

  @override
  String get onboardingValueProp2Title => 'Nadie puede cerrarlo';

  @override
  String get onboardingValueProp3Title => 'No necesitas cuenta';

  @override
  String get onboardingValueProp1Summary =>
      'Se cifra en tu dispositivo, así solo los círculos que elijas pueden leerla.';

  @override
  String get onboardingValueProp2Summary =>
      'Sin servidor central. Funciona en una red de relés que tú eliges.';

  @override
  String get onboardingValueProp3Summary =>
      'Sin correo, teléfono ni registro. Tu clave secreta nunca sale de tu teléfono.';

  @override
  String get onboardingCreateIdentityTitle => 'Crea tu identidad';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven crea tus claves en este teléfono. La secreta no sale nunca de él.';

  @override
  String get onboardingCreateIdentityWarning =>
      'Si pierdes este teléfono o eliminas la app, tu identidad desaparece. Haven no tiene forma de recuperarla por ti.';

  @override
  String get onboardingCreateIdentityCta => 'Crear mi identidad';

  @override
  String get onboardingCreateIdentityLoading => 'Preparándolo todo…';

  @override
  String get onboardingCreateIdentityImportPrompt => '¿Ya tienes una clave?';

  @override
  String get onboardingCreateIdentityImportLink => 'Impórtala en su lugar';

  @override
  String get onboardingCreateIdentityError =>
      'Algo salió mal al crear tu identidad. Inténtalo de nuevo.';

  @override
  String get onboardingImportTitle => 'Importa tu clave existente';

  @override
  String get onboardingImportBody =>
      'Pega la clave secreta que respaldaste desde otra app compatible con Haven.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'Importar';

  @override
  String get onboardingImportLoading => 'Importando…';

  @override
  String get onboardingImportInvalid =>
      'Eso no parece una clave de respaldo válida. Compruébala e inténtalo de nuevo.';

  @override
  String get onboardingImportError =>
      'No pudimos importar esa clave. Compruébala e inténtalo de nuevo.';

  @override
  String get onboardingDisplayNameHint => 'p. ej., Alex';

  @override
  String get onboardingDisplayNameError =>
      'No se pudo guardar ese nombre. Inténtalo de nuevo.';

  @override
  String get onboardingAddPhotoOptional => 'Añadir una foto (opcional)';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonOpenSettings => 'Abrir ajustes';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get settingsIdentityTitle => 'Identidad';

  @override
  String get settingsRelaysTitle => 'Relés';

  @override
  String get settingsLocationTitle => 'Ubicación';

  @override
  String get settingsLocationSubtitleOn =>
      'Compartir en segundo plano activado';

  @override
  String get settingsLocationSubtitleOff => 'Solo mientras Haven está abierto';

  @override
  String get settingsMapStyleTitle => 'Estilo del mapa';

  @override
  String get settingsAboutTitle => 'Acerca de';

  @override
  String get settingsDebugOverlayTitle =>
      'Superposición de registro de depuración';

  @override
  String get settingsDebugOverlaySubtitle =>
      'Mostrar la salida del registro en pantalla';

  @override
  String get relaySettingsTitle => 'Relés';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Comprobar relés';

  @override
  String get relaySettingsNoIdentityTitle => 'Sin identidad';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Crea primero una identidad para gestionar los relés.';

  @override
  String get relaySettingsLoadIdentityError =>
      'No se pudo cargar la identidad.';

  @override
  String get relaySettingsInboxTitle => 'Mis relés de bandeja de entrada';

  @override
  String get relaySettingsInboxSubtitle =>
      'Por donde te llegan las invitaciones (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'Mis relés de KeyPackage';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'Donde los demás encuentran las claves que necesitan para invitarte (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'Mis relés de perfil';

  @override
  String get relaySettingsProfileSubtitle =>
      'Donde se consulta y se publica tu perfil público. Estos relés se mantienen aparte de tus demás relés, y la lista de relés de perfil nunca se publica (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'Consultas de perfil en pausa';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'No quedan suficientes relés de perfil, así que los nombres y las fotos de los miembros dejarán de actualizarse.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Restaurar relés de perfil predeterminados';

  @override
  String get relaySettingsLoadRelaysError => 'No se pudieron cargar los relés.';

  @override
  String get relaySettingsAddRelay => 'Añadir relé';

  @override
  String get relaySettingsRestoreDefaults => 'Restaurar predeterminados';

  @override
  String get relaySettingsAddRelayError => 'No se pudo añadir el relé.';

  @override
  String get relaySettingsRemoveRelayError => 'No se pudo quitar el relé.';

  @override
  String get relaySettingsRestoreTitle =>
      '¿Restaurar los relés predeterminados?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Tus $countString relés actuales se reemplazarán por los predeterminados de Haven. Esto no se puede deshacer.',
      many:
          'Tus $countString relés actuales se reemplazarán por los predeterminados de Haven. Esto no se puede deshacer.',
      one:
          'Tu $countString relé actual se reemplazará por los predeterminados de Haven. Esto no se puede deshacer.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Restaurar';

  @override
  String get relaySettingsRestoreSuccess => 'Predeterminados restaurados.';

  @override
  String get relaySettingsRestoreError =>
      'No se pudieron restaurar los predeterminados.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'Quitar $url';
  }

  @override
  String get relaySettingsStatusConnected => 'Conectado';

  @override
  String get relaySettingsStatusChecking => 'Comprobando';

  @override
  String get relaySettingsStatusUnreachable => 'Sin acceso';

  @override
  String get relaySettingsStatusNotChecked => 'Sin comprobar';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'Estado del relé: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'No hay relés configurados';

  @override
  String get relaySettingsEmptyMessage =>
      'Necesitas al menos un relé para que otros puedan localizarte. Toca abajo para restaurar los predeterminados de Haven.';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'También lleva otro tráfico de Haven';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Advertencia: $url también lleva tu otro tráfico de Haven, así que este relé podría vincular tu perfil con ese tráfico';
  }

  @override
  String get locationSettingsTitle => 'Ubicación';

  @override
  String get locationSettingsDisabledSnack =>
      'Compartir en segundo plano desactivado';

  @override
  String get locationSettingsEnabledSnack =>
      'Compartir en segundo plano activado';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'Compartir en segundo plano necesita una notificación para que Android lo mantenga activo. Por ahora está desactivado. Activa las notificaciones de Haven para habilitarlo.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'Activado. La optimización de batería puede pausar el uso compartido en algunos teléfonos. Excluye Haven de la optimización de batería para que sea fiable.';

  @override
  String get locationSettingsBatteryOptNote =>
      'La optimización de batería sigue activada para Haven. Algunos teléfonos la usan para detener el uso compartido en segundo plano sin avisar. Excluye Haven para que el uso compartido siga siendo fiable.';

  @override
  String get locationSettingsErrorSnack => 'Algo salió mal';

  @override
  String get locationSettingsIntro =>
      'Haven comparte tu ubicación con tus círculos siempre que la app está abierta. Activa esto y tus círculos la seguirán viendo mientras Haven está en segundo plano. Si el sistema cierra Haven, tu ubicación deja de compartirse: puede que Haven aún se despierte para recibir las ubicaciones de tus círculos, pero nunca para enviar la tuya. En Android, el envío de tu ubicación continúa aunque deslices Haven fuera del selector de apps, y vuelve a empezar por sí solo tras reiniciar el teléfono. En iPhone, el envío de tu ubicación sigue detenido hasta que abras Haven.';

  @override
  String get locationSettingsToggleTitle => 'Compartir en segundo plano';

  @override
  String get locationSettingsToggleSubtitle =>
      'Seguir compartiendo mientras Haven esté en segundo plano';

  @override
  String get locationSettingsIosLimitedNote =>
      'El uso compartido sigue funcionando en segundo plano con tu permiso actual, y mientras lo hace, iOS muestra su barra azul de ubicación en la parte superior de la pantalla. Configura la Ubicación de Haven como «Siempre» en Ajustes para que Haven también pueda ponerse al día con las ubicaciones de tus círculos después de que iOS cierre la app. Con «Siempre», iOS puede mostrar su flecha de ubicación en la barra de estado en lugar de esa barra azul. Tu propio uso compartido solo se reanuda cuando vuelves a abrir Haven.';

  @override
  String get locationSettingsAndroidHeader =>
      'Ajustes del sistema para mayor fiabilidad';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven necesita una notificación persistente para que Android mantenga vivo el servicio en segundo plano. Si denegaste el permiso de notificaciones, abre Ajustes y permite las notificaciones de Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'Para compartir en segundo plano de forma fiable, excluye también Haven de la optimización de batería. Ve a Ajustes → Aplicaciones → Haven → Batería → Permitir siempre.';

  @override
  String get locationSettingsAndroidVendors =>
      'En dispositivos Samsung, quita Haven de «Aplicaciones inactivas» (Mantenimiento del dispositivo → Batería → Límites de uso en segundo plano). En Xiaomi, activa el inicio automático para Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'Mientras compartir en segundo plano está activado, Haven mantiene una sesión de ubicación para que tus círculos sigan viéndote.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'iOS muestra su flecha de ubicación en la barra de estado mientras Haven usa tu ubicación, y después mantiene esa misma flecha junto a Haven en los ajustes de Localización durante un tiempo.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'Con tu permiso «Siempre», iOS muestra su barra azul de ubicación en la parte superior de la pantalla mientras Haven usa tu ubicación.';

  @override
  String get locationDisclosureTitle => 'Compartir tu ubicación';

  @override
  String get locationDisclosureWhy =>
      'Haven muestra tu ubicación en tiempo real a las personas de los círculos que elijas, y a ti te muestra su ubicación en el mapa. Para eso, Haven necesita permiso para usar la ubicación precisa de tu dispositivo.';

  @override
  String get locationDisclosureHow =>
      'Tu ubicación se cifra de extremo a extremo en tu dispositivo, así que solo los miembros de los círculos que elijas pueden leerla; Haven no. Haven no tiene servidores propios: tus actualizaciones cifradas pasan por relés independientes que gestionan otras personas. Esos relés ven tu dirección de red, pero nunca dónde estás. Para dibujar el mapa, Haven le pide a Stadia Maps las zonas que rodean tu ubicación y la de tu círculo, así que Stadia Maps sabe más o menos dónde es eso, pero nunca tu nombre, ni tu clave, ni quién está en tus círculos. Stadia Maps afirma que no vende ni intercambia información personal, que no instala cookies en tu dispositivo y que conserva los registros de sus servidores unas dos semanas: es su propia política, y Haven no puede hacerla cumplir.';

  @override
  String get locationDisclosureSharing =>
      'Mientras Haven está abierto y estás en un círculo, tu ubicación se envía automáticamente cada pocos minutos. No hay forma de pausarlo. Para dejar de compartir con un círculo, sal de él.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'Esta app usa datos de ubicación para permitir el uso compartido con tus círculos incluso cuando la app está cerrada o no está en uso.';

  @override
  String get locationDisclosureBackgroundIos =>
      'Esta app usa datos de ubicación para permitir el uso compartido con tus círculos incluso cuando Haven está en segundo plano y no lo estás usando. Si iOS cierra Haven, el uso compartido se detiene hasta que vuelvas a abrirlo: puede que Haven aún se despierte para recibir las ubicaciones de tus círculos, pero nunca para enviar la tuya.';

  @override
  String get locationDisclosureManage =>
      'Puedes desactivar el uso compartido en segundo plano cuando quieras, en Ajustes → Ubicación.';

  @override
  String get locationDisclosureAgree => 'Aceptar';

  @override
  String get locationDisclosureNotNow => 'Ahora no';

  @override
  String get fgsNotificationSharing =>
      'Haven está enviando y recibiendo información de ubicación';

  @override
  String get fgsNotificationPaused =>
      'Haven está en pausa: abre la app para reanudar el uso compartido';

  @override
  String get fgsNotificationOpen => 'Haven está abierto';

  @override
  String get fgsChannelName => 'Uso compartido de ubicación';

  @override
  String get fgsChannelDescription =>
      'Hace que Haven siga compartiendo tu ubicación cifrada en segundo plano.';

  @override
  String get mapStyleTitle => 'Estilo del mapa';

  @override
  String get mapStyleMinimalTitle => 'Minimalista';

  @override
  String get mapStyleMinimalSubtitle =>
      'Lienzo sereno y de poco detalle que sigue tu tema claro u oscuro';

  @override
  String get mapStyleDetailedTitle => 'Detallado';

  @override
  String get mapStyleDetailedSubtitle =>
      'Calles, etiquetas y lugares a todo color';

  @override
  String get mapStyleOutdoorsTitle => 'Aire libre';

  @override
  String get mapStyleOutdoorsSubtitle =>
      'Terreno sombreado con senderos y parques';

  @override
  String get mapStylePreviewHeader => 'Vista previa';

  @override
  String get mapStylePreviewCity => 'Ciudad';

  @override
  String get mapStylePreviewNature => 'Naturaleza';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Vista previa del mapa ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Vista previa del mapa no disponible en esta versión';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'La vista previa en directo aparece en las versiones de lanzamiento';

  @override
  String get aboutTitle => 'Acerca de';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'Compartir ubicación de forma privada y resistente a la censura.';

  @override
  String get aboutLicensesTitle => 'Licencias de código abierto';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · Licencia MIT';

  @override
  String get aboutReportMapIssue => 'Informar de un problema del mapa';

  @override
  String get aboutSupportOsm => 'Apoyar a OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nDatos del mapa con licencia ODbL';

  @override
  String get aboutLinkOpenError => 'No se pudo abrir el enlace';

  @override
  String get aboutFooterLicense => 'Con licencia MIT';

  @override
  String aboutFooterVersion(String version) {
    return 'Versión $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven no tiene servidor propio. Tus actualizaciones cifradas pasan por servidores independientes llamados relés, que no pueden leer tu ubicación ni tus mensajes.';

  @override
  String get commonClearAll => 'Borrar todo';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString miembros',
      many: '$countString miembros',
      one: '$countString miembro',
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
  String get circlesTitle => 'Círculos';

  @override
  String get circlesRefreshTooltip => 'Actualizar círculos';

  @override
  String get circlesRequiresIdentity =>
      'Para crear un círculo primero hay que configurar la identidad';

  @override
  String get circlesCreateCta => 'Crear círculo';

  @override
  String get circlesYourCircles => 'Tus círculos';

  @override
  String get circlesEmptyTitle => 'Aún no hay círculos';

  @override
  String get circlesEmptyMessage =>
      'Crea un círculo para empezar a compartir tu ubicación con amigos y familiares de confianza.';

  @override
  String get circlesSheetEmptyMessage =>
      'Crea un círculo para empezar a compartir tu ubicación con contactos de confianza.';

  @override
  String get circlesLoadError => 'No se pudieron cargar los círculos';

  @override
  String get circlesSelectToView =>
      'Selecciona un círculo para ver sus miembros';

  @override
  String get circlesNoMembers => 'No hay miembros en este círculo';

  @override
  String get createCircleTitle => 'Añadir miembros';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Seleccionados ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Añade miembros al círculo';

  @override
  String get createCircleEmptyMessage =>
      'Busca por ID o escanea su código QR para añadir miembros.';

  @override
  String get createCircleNoValidMembers =>
      'No hay miembros válidos para invitar';

  @override
  String get createCircleNoIdInQr =>
      'No se encontró ningún ID válido en el código QR';

  @override
  String get createCircleNoAccountFound =>
      'No se encontró ninguna cuenta de Haven para este ID';

  @override
  String get createCircleCouldNotVerify => 'No se pudo verificar al miembro';

  @override
  String get createCircleSomethingWentWrong => 'Algo salió mal';

  @override
  String get nameCircleTitle => 'Nombra tu círculo';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se invitará a $countString miembros',
      many: 'Se invitará a $countString miembros',
      one: 'Se invitará a $countString miembro',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Nombre del círculo';

  @override
  String get nameCircleNameHint => 'p. ej., Familia, Amigos cercanos';

  @override
  String get nameCircleNameEmptyError => 'Introduce un nombre para el círculo';

  @override
  String get nameCircleNameTooLongError =>
      'El nombre debe tener 50 caracteres o menos';

  @override
  String get nameCircleSharingInfo =>
      'Todos en este círculo pueden ver la ubicación, el nombre público y la foto de los demás. Tu nombre y tu foto son públicos en la red Nostr, no son privados de este círculo. Este círculo permanece separado de cualquier otro en el que estés, así que sus miembros no pueden ver tus otros círculos ni quién está en ellos.';

  @override
  String get nameCircleCreateCta => 'Crear círculo';

  @override
  String get nameCircleStageCreatingGroup => 'Creando grupo seguro...';

  @override
  String get nameCircleStageComplete => '¡Listo!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Progreso de creación: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString por ciento completado';
  }

  @override
  String nameCircleCreatedSentSoFarSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          'Círculo \"$name\" creado. Invitaciones enviadas hasta ahora: $sentString de $totalString. Haven sigue intentando enviar las demás mientras la app está abierta, durante un día como máximo.',
      many:
          'Círculo \"$name\" creado. Invitaciones enviadas hasta ahora: $sentString de $totalString. Haven sigue intentando enviar las demás mientras la app está abierta, durante un día como máximo.',
      one:
          'Círculo \"$name\" creado. Invitación enviada hasta ahora: $sentString de 1. Haven sigue intentando enviarla mientras la app está abierta, durante un día como máximo.',
    );
    return '$_temp0';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '¡Círculo \"$name\" creado! Se enviaron $countString invitaciones.',
      many: '¡Círculo \"$name\" creado! Se enviaron $countString invitaciones.',
      one: '¡Círculo \"$name\" creado! Se envió $countString invitación.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Error de identidad. Comprueba la configuración de tu identidad.';

  @override
  String get nameCircleCreateError =>
      'No se pudo crear el círculo. Inténtalo de nuevo.';

  @override
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Solo puedes estar en $limitString círculos a la vez. Sal de un círculo para poder crear uno nuevo.';
  }

  @override
  String addMemberTitle(String circleName) {
    return 'Añadir a $circleName';
  }

  @override
  String get addMemberInfo =>
      'En cuanto acepte, verá la ubicación de todos a partir de ese momento, nunca nada de lo enviado antes de que se uniera. También verá las claves públicas de todas las personas que ya están en este círculo.';

  @override
  String get addMemberAlreadyInCircle => 'Ya está en este círculo';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Enviar invitaciones',
      many: 'Enviar invitaciones',
      one: 'Enviar invitación',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Enviando invitaciones...',
      many: 'Enviando invitaciones...',
      one: 'Enviando invitación...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Invitaciones enviadas a $circleName',
      many: 'Invitaciones enviadas a $circleName',
      one: 'Invitación enviada a $circleName',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentSoFar(int sent, int total, String circleName) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          'Invitaciones a $circleName enviadas hasta ahora: $sentString de $totalString. Haven sigue intentando enviar las demás mientras la app está abierta, durante un día como máximo.',
      many:
          'Invitaciones a $circleName enviadas hasta ahora: $sentString de $totalString. Haven sigue intentando enviar las demás mientras la app está abierta, durante un día como máximo.',
      one:
          'Invitación a $circleName enviada hasta ahora: $sentString de 1. Haven sigue intentando enviarla mientras la app está abierta, durante un día como máximo.',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'Haven no puede enviar la invitación a $circleName. Quita a esa persona y vuelve a añadirla.';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven no puede invitar a todas las personas que elegiste, porque no ha encontrado adónde enviar al menos una de sus invitaciones. Pide a las personas que elegiste que comprueben que su app puede recibir invitaciones y, después, vuelve a intentarlo.';

  @override
  String get missedInvitationsShowWho => 'Ver quién';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Invitaciones no enviadas',
      many: 'Invitaciones no enviadas',
      one: 'Invitación no enviada',
    );
    return '$_temp0';
  }

  @override
  String get addMemberError =>
      'No se pudo añadir al miembro. Inténtalo de nuevo.';

  @override
  String get qrScannerTitle => 'Escanear código QR';

  @override
  String get qrScannerToggleFlash => 'Alternar flash';

  @override
  String get qrScannerSwitchCamera => 'Cambiar de cámara';

  @override
  String get qrScannerInstruction => 'Coloca el código QR dentro del marco';

  @override
  String get qrScannerScanning => 'Escaneando...';

  @override
  String get circleMemberNoRecentLocation => 'Sin ubicación reciente';

  @override
  String get circleMemberRemoveTooltip => 'Quitar del círculo';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '¿Quitar a $name?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'Esa persona deja de poder leer nada nuevo de este círculo en cuanto el resto del círculo se pone al día. Eso suele tardar unos minutos, y más si alguien estaba sin conexión en ese momento. Lo que ya recibió se queda en su teléfono. Para deshacerlo, tendrías que enviarle una invitación nueva.';

  @override
  String get circleMemberRemoveConfirm => 'Quitar';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'Quitando a $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return 'Se ha quitado a $name del círculo';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'No se pudo quitar a $name. No ha cambiado nada: comprueba tu conexión e inténtalo de nuevo.';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return 'Todavía se está quitando a $name: a la espera de los relés. Hasta que se complete, no se comparte nada con este círculo.';
  }

  @override
  String get circleMemberAdmin => 'Administrador';

  @override
  String get circleMemberHintNoLocation => 'sin ubicación disponible';

  @override
  String get circleMemberHintMember => 'miembro';

  @override
  String get circleMemberHintTapToCenter =>
      'toca para centrar el mapa en su ubicación';

  @override
  String get pendingMemberRetryTooltip => 'Reintentar validación';

  @override
  String get pendingMemberRemoveTooltip => 'Quitar de la lista';

  @override
  String get pendingMemberValidating => 'Validando';

  @override
  String get pendingMemberValid => 'Válido';

  @override
  String get pendingMemberWarning => 'Advertencia';

  @override
  String get pendingMemberCheckingAvailability =>
      'Comprobando disponibilidad...';

  @override
  String get pendingMemberReadyToInvite => 'Listo para invitar';

  @override
  String get pendingMemberNeedsUpdate => 'Necesita actualizar o abrir Haven';

  @override
  String get memberKeyPackageStale =>
      'Haven no puede invitar a esta persona ahora mismo. Pídele que abra Haven y vuelve a intentarlo.';

  @override
  String get memberSearchHint => 'Introduce el ID del miembro...';

  @override
  String get memberSearchPasteTooltip => 'Pegar desde el portapapeles';

  @override
  String get memberSearchAddTooltip => 'Añadir miembro';

  @override
  String get memberSearchScanTooltip => 'Escanear código QR';

  @override
  String get memberSearchHelper =>
      'Pide a tus contactos su código QR o ID de Haven';

  @override
  String get memberSearchNoValidId =>
      'No se encontró ningún ID de Haven válido';

  @override
  String get memberSearchAlreadyAdded => 'Ya está en la lista';

  @override
  String get memberPickerSectionRoster => 'Miembros de tus círculos';

  @override
  String get memberPickerTierRoster => 'Miembro de tus círculos';

  @override
  String get memberPickerNoMatches => 'No hay coincidencias en tus círculos';

  @override
  String get memberPickerLoading =>
      'Cargando la lista de personas de tus círculos';

  @override
  String get memberPickerDirectoryUnavailable =>
      'En este momento no se pudo cargar la lista de personas de tus círculos';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Coincidencias: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'Este es tu propio ID';

  @override
  String get memberPickerReadPublicKey => 'Leer clave pública en voz alta';

  @override
  String get memberPickerSectionRecent => 'Recientemente en tus círculos';

  @override
  String get memberPickerTierRecent => 'Recientemente en tus círculos';

  @override
  String get memberPickerNicknameNote =>
      'Tu apodo para esta persona, no su nombre público';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'Círculo: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven le ha pedido a un relé el nombre publicado de esta persona. Ese relé puede ver que este dispositivo acaba de preguntar por esta clave, pero la consulta no lleva firma, así que no queda ligada a tu identidad de Haven. Todavía no se ha descargado ninguna foto.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString más';
  }

  @override
  String get invitationCardHeading => 'Invitación a un círculo';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Invitación para unirte a un círculo, enviada por $inviter';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Invitación enviada por el identificador criptográfico $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Invitación de: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'Tu apodo para esta persona, no su nombre público';

  @override
  String get invitationCardJustNow => 'Ahora mismo';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'hace ${countString}d';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'hace ${countString}h';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'hace ${countString}m';
  }

  @override
  String get invitationCardDecline => 'Rechazar';

  @override
  String get invitationCardAccept => 'Aceptar';

  @override
  String get invitationAcceptedSnack => 'Invitación aceptada';

  @override
  String get invitationDeclinedSnack => 'Invitación rechazada';

  @override
  String get invitationAcceptError =>
      'No se pudo aceptar la invitación. Inténtalo de nuevo.';

  @override
  String invitationNeedsNewInviteError(String name) {
    return 'Esta invitación ya no se puede usar. Pide a $name que te invite de nuevo. Puede que primero tenga que actualizar Haven.';
  }

  @override
  String get rejoinDialogTitle => '¿Volver a unirte a este círculo?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName te ha invitado a «$circleName», que ya está en este teléfono. Puede pasar si te quitaron del círculo y te volvieron a invitar. Si vuelves a unirte, se reemplazará la copia del círculo que hay en este teléfono. Rechazar pone fin a esta invitación para siempre; Cancelar la conserva para más adelante.';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'Te han invitado a «$circleName», que ya está en este teléfono. Puede pasar si te quitaron del círculo y te volvieron a invitar. Si vuelves a unirte, se reemplazará la copia del círculo que hay en este teléfono. Rechazar pone fin a esta invitación para siempre; Cancelar la conserva para más adelante.';
  }

  @override
  String get rejoinDialogConfirm => 'Volver a unirme';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Solo puedes estar en $limitString círculos a la vez. Sal de un círculo y luego podrás aceptar esta invitación.';
  }

  @override
  String get invitationDeclineError =>
      'No se pudo rechazar la invitación. Inténtalo de nuevo.';

  @override
  String get circleSelectorLabel => 'Selector de círculo';

  @override
  String get circleSelectorPlaceholder => 'Selecciona un círculo';

  @override
  String get circleSelectorNewCircle => 'Nuevo círculo';

  @override
  String get circleSelectorLoadError => 'No se pudieron cargar los círculos';

  @override
  String get circleSelectorExpandedAnnouncement =>
      'Lista de círculos expandida';

  @override
  String get circleSelectorCollapsedAnnouncement =>
      'Lista de círculos contraída';

  @override
  String get circleDetailsButtonTooltip => 'Detalles del círculo';

  @override
  String get circleDetailsTitle => 'Detalles del círculo';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · época $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · caducidad $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString min',
      many: '$countString min',
      one: '$countString min',
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
      other: '$countString s',
      many: '$countString s',
      one: '$countString s',
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
      other: 'aproximadamente $countString minutos',
      many: 'aproximadamente $countString minutos',
      one: 'aproximadamente $countString minuto',
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
      other: '$countString segundos',
      many: '$countString segundos',
      one: '$countString segundo',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven pide a los relés que, al cabo de $expiry, descarten las actualizaciones de ubicación que envías a este círculo.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relés de este círculo';

  @override
  String get circleDetailsNoRelays => '(ninguno registrado)';

  @override
  String get circleDetailsRelaysNote =>
      'Estos relés vienen de las listas publicadas por los miembros invitados; si esos miembros no tenían ninguna, de tus relés de bandeja de entrada o de algunos que eligió Haven. Aún no se pueden cambiar, y los cambios posteriores en tu lista de relés no los afectan.';

  @override
  String get circleDetailsAddMember => 'Añadir miembro';

  @override
  String get circleDetailsLeaveCircle => 'Salir del círculo';

  @override
  String get circleDetailsLeavingInProgress => 'Saliendo del círculo…';

  @override
  String get leaveCircleDialogTitle => 'Salir del círculo';

  @override
  String get leaveCircleDialogBody =>
      '¿Salir de este círculo? Dejarás de enviar tu ubicación a sus miembros y de ver la suya. La última ubicación que enviaste se queda en sus teléfonos durante un día como máximo. Esto no se puede deshacer: necesitarías una invitación nueva para volver.';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'Este círculo ha terminado, así que ya no se comparte nada con él. Salir del círculo lo quita de este teléfono.';

  @override
  String get leaveCircleDialogAdminNote =>
      'Tienes el rol de Administrador en este círculo. Antes de que salgas, Haven intenta dar ese rol a otra persona del círculo para que el círculo pueda seguir funcionando.';

  @override
  String get leaveCircleConfirm => 'Salir';

  @override
  String get leaveCircleIdentityUnavailable => 'Identidad no disponible';

  @override
  String get leaveCircleSuccess => 'Saliste del círculo correctamente';

  @override
  String get leaveCircleError => 'No se pudo salir del círculo';

  @override
  String get legacyCircleRecreateCta => 'Volver a crear círculo';

  @override
  String get storageResetTitle => 'Haven se ha actualizado';

  @override
  String get storageResetKept =>
      'Tu identidad no ha cambiado, y el perfil público que ya publicaste sigue igual.';

  @override
  String get storageResetLost =>
      'Para pasar al nuevo motor de cifrado de Haven, se eliminaron los círculos creados antes de esta actualización. Vuelve a crearlos e invita de nuevo a sus miembros. También se eliminaron los apodos que pusiste a otras personas antes de esta actualización y cualquier cambio de perfil que para entonces no se hubiera terminado de guardar.';

  @override
  String get storageResetRelays =>
      'Esta actualización restableció tus ajustes de relés a los valores predeterminados de Haven. No se publicarán hasta que continúes o vuelvas de Ajustes de relés, así que puedes añadir primero tus propios relés.';

  @override
  String get storageResetContinue => 'Continuar';

  @override
  String get storageResetOpenRelaySettings => 'Ajustes de relés';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven no pudo guardar tu respuesta. Hasta que se guarde, Haven no publicará tus ajustes de relés ni tu clave de invitación, así que nadie puede invitarte todavía. Vuelve a intentarlo o Haven te lo volverá a preguntar la próxima vez que se abra.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'Panel de círculos contraído';

  @override
  String get circlesPanelExpandedAnnouncement => 'Panel de círculos expandido';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'Panel de círculos ligeramente abierto';

  @override
  String get circlesPanelHalfOpenAnnouncement =>
      'Panel de círculos abierto a la mitad';

  @override
  String get circleMemberAnnouncementSelf => 'tú';

  @override
  String get circleMemberAnnouncementFallback => 'miembro';

  @override
  String get invitationsRefreshTooltip => 'Actualizar invitaciones';

  @override
  String get invitationsLoadError => 'No se pudieron cargar las invitaciones';

  @override
  String get invitationsEmptyTitle => 'Sin invitaciones';

  @override
  String get invitationsEmptyMessage =>
      'Cuando alguien te invite a un círculo, aparecerá aquí.';

  @override
  String get refreshRingSemanticNoInbox =>
      'No hay bandeja de entrada configurada, abre los ajustes de relés';

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
      other: '$checkedString de $totalString relés comprobados',
      many: '$checkedString de $totalString relés comprobados',
      one: '$checkedString de 1 relé comprobado',
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
      other: 'Todos los $totalString relés respondieron',
      many: 'Todos los $totalString relés respondieron',
      one: 'El relé respondió',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'Ningún relé respondió';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relés respondieron';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Comprobando relés';

  @override
  String get refreshRingAnnouncementAllOk => 'Todos los relés respondieron';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relés respondieron';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'No se pudo contactar con ningún relé';

  @override
  String get refreshRingAnnouncementNoInbox =>
      'No hay bandeja de entrada configurada';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'Todos los $totalString relés tienen tus datos',
      many: 'Todos los $totalString relés tienen tus datos',
      one: 'El relé tiene tus datos',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'Ningún relé tiene tus datos';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relés tienen tus datos';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'Todos los relés tienen tus datos';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relés tienen tus datos';
  }

  @override
  String get refreshRingAnnouncementNoneFound => 'Ningún relé tiene tus datos';

  @override
  String get identityTitle => 'Identidad';

  @override
  String get identityLoadError =>
      'Algo salió mal al cargar tu identidad. Inténtalo de nuevo.';

  @override
  String get identityMissingTitle => 'Sin identidad';

  @override
  String get identityMissingMessage =>
      'Tu identidad ha desaparecido. Configura una nueva para seguir usando Haven.';

  @override
  String get identitySetUpCta => 'Configurar identidad';

  @override
  String get identityPublicKeyQrTitle => 'QR de la clave pública';

  @override
  String get identityPublicKeyQrSubtitle =>
      'Cómo te invitan otros a sus círculos';

  @override
  String get identityAdvancedTitle => 'Avanzado';

  @override
  String get identityAdvancedSubtitle =>
      'Clave pública, clave secreta, eliminar';

  @override
  String get profileIsPublicNoticeTitle => 'Tu perfil es público';

  @override
  String get profileIsPublicNoticeBody =>
      'Tu nombre visible y tu foto son visibles para cualquiera en la red Nostr, no solo para los miembros de tus círculos. Comparte solo lo que no te importe hacer público.';

  @override
  String get identityRefreshProfileTooltip => 'Actualizar perfil público';

  @override
  String get identityAdvancedExportError =>
      'No se pudo exportar la clave secreta. Inténtalo de nuevo.';

  @override
  String get identityAdvancedDeleteTitle => '¿Eliminar la identidad?';

  @override
  String get identityAdvancedDeleteBody =>
      'Esto elimina tu identidad y todos los datos de tus círculos de este teléfono. Todo lo que ya se haya publicado con ella se queda donde está: tu nombre y tus claves en los relés que los tengan, y tu foto en el alojamiento de imágenes que la guarda. Asegúrate de haber respaldado tu clave secreta si quieres poder recuperar esa identidad.';

  @override
  String get identityAdvancedDeleteConfirm => 'Eliminar';

  @override
  String get identityAdvancedDeletedSnack => 'Identidad eliminada';

  @override
  String get identityAdvancedDeleteError =>
      'No se pudo eliminar la identidad. Inténtalo de nuevo.';

  @override
  String get identityAdvancedDeletingProgress => 'Eliminando tu identidad…';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label copiado al portapapeles';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Clave secreta copiada. Advertencia: otras apps pueden leer tu portapapeles. Pégala en un lugar seguro y borra tu portapapeles.';

  @override
  String get identityAdvancedMissingBody =>
      'No hay ninguna identidad configurada.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Clave pública';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'Clave pública (hex)';

  @override
  String get identityAdvancedCopyValue => 'Clave pública';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'Copiar clave pública';

  @override
  String get identityAdvancedCopyHexTooltip => 'Copiar hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'Clave secreta';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Tu clave secreta da acceso total a tu identidad. No la compartas nunca con nadie.';

  @override
  String get identityAdvancedRevealSecretKey => 'Mostrar clave secreta';

  @override
  String get identityAdvancedHideSecretKey => 'Ocultar clave secreta';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'Copiar clave secreta';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Eliminar identidad';

  @override
  String get qrCodeLoadError =>
      'Algo salió mal al cargar tu clave pública. Inténtalo de nuevo.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Tu clave pública';

  @override
  String get qrCodeWhatIsThisTitle => '¿Qué es esto?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven funciona sobre Nostr, una red abierta sin ninguna cuenta de empresa ni registro detrás. Tu identidad no es más que un par de claves: una clave secreta que solo tú posees, y esta clave pública generada a partir de ella.';

  @override
  String get qrCodeExplainerUsername =>
      'Tu clave pública funciona como un nombre de usuario que es seguro compartir. Las personas escanean este código, o pegan tu clave pública, para invitarte a un círculo. Compartirla no puede revelar dónde estás. Tu nombre visible y tu foto ya son públicos, así que esto no añade nada.';

  @override
  String get displayNameCardTitle => 'Nombre visible';

  @override
  String get displayNameCardLoadError =>
      'No se pudo cargar tu nombre visible. Inténtalo más tarde.';

  @override
  String get displayNameCardHint => 'Introduce tu nombre visible';

  @override
  String get displayNameCardSavedLabel => 'Nombre visible guardado';

  @override
  String get displayNameCardSaveLabel => 'Guardar nombre visible';

  @override
  String get displayNameCardSavingLabel => 'Guardando nombre visible';

  @override
  String get displayNameCardRetryLabel => 'Error al guardar. Reintentar';

  @override
  String get displayNameCardSavedAnnouncement => 'Nombre visible guardado';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'Error al guardar, inténtalo de nuevo';

  @override
  String get profileSyncStatusSyncing => 'Sincronizando con tu perfil público…';

  @override
  String get profileSyncStatusPartial =>
      'Publicado: aún sincronizando con algunos relés';

  @override
  String get profileSyncStatusSynced => 'Perfil público actualizado';

  @override
  String get profileSyncStatusFailed => 'Aún no se pudo sincronizar.';

  @override
  String get profileSyncStatusRetrySemantics => 'Reintentar publicar tu perfil';

  @override
  String get npubQrCopiedSnack => 'Clave pública copiada al portapapeles';

  @override
  String get npubQrCopyButton => 'Copiar clave pública';

  @override
  String get circleMemberPublicKeyCopied =>
      'Clave pública copiada al portapapeles';

  @override
  String get circleMemberCopyPublicKeyHint => 'Copiar clave pública';

  @override
  String get circleMemberSetNicknameMenuItem => 'Poner apodo';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'Copiar clave pública';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'No se pudieron actualizar los perfiles. Inténtalo de nuevo.';

  @override
  String get memberDetailSheetTitle => 'Detalles del miembro';

  @override
  String get memberNicknameSheetHint => 'Introduce un apodo';

  @override
  String get memberNicknameSheetLabel => 'Apodo';

  @override
  String get memberNicknameSheetSave => 'Guardar apodo';

  @override
  String get memberNicknameSheetClear => 'Borrar apodo';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Apodo guardado';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Apodo borrado';

  @override
  String get npubQrScanLabel => 'Escanéame para añadirme';

  @override
  String get npubQrSemanticsLabel => 'Código QR de tu identidad pública';

  @override
  String get photoHeaderRemoveTitle => '¿Quitar la foto de perfil?';

  @override
  String get photoHeaderRemoveBody =>
      'Esto quita tu foto de tu perfil público. El archivo de imagen sigue en el servidor que lo aloja, y las copias que otras personas ya hayan descargado se quedan con ellas.';

  @override
  String get photoHeaderEditPhoto => 'Editar foto';

  @override
  String get photoHeaderRemove => 'Quitar';

  @override
  String get photoHeaderViewPhotoSemantics => 'Ver foto de perfil';

  @override
  String get photoHeaderAddPhotoSemantics => 'Añadir foto de perfil';

  @override
  String get photoHeaderChangePhotoSemantics => 'Cambiar foto de perfil';

  @override
  String get avatarPickerPhotoUpdated =>
      'Foto actualizada. Se publicará en tu perfil público de Nostr.';

  @override
  String get avatarPickerPhotoRemoved => 'Foto quitada.';

  @override
  String get avatarPickerRemoveError =>
      'No se pudo quitar tu foto. Inténtalo de nuevo.';

  @override
  String get avatarPickerUpdateError =>
      'No se pudo actualizar tu foto. Inténtalo de nuevo.';

  @override
  String get avatarPickerCropTitle => 'Recortar foto';

  @override
  String get avatarPickerCropDone => 'Listo';

  @override
  String get avatarPickerCropCancel => 'Cancelar';

  @override
  String get avatarFullscreenClose => 'Cerrar';

  @override
  String get avatarFullscreenSemantics => 'Foto de perfil, pantalla completa';

  @override
  String get avatarFullscreenLoadError => 'No se pudo cargar la foto';

  @override
  String get mapInitializing => 'Inicializando...';

  @override
  String get mapInitFailedTitle => 'Error de inicialización';

  @override
  String get mapInitFailedMessage =>
      'No se pudieron inicializar los servicios de ubicación.';

  @override
  String get mapInitFailedRetry =>
      'Error de inicialización. Inténtalo de nuevo.';

  @override
  String get mapLocationOffMessage =>
      'Activa la ubicación para verte a ti y a tus círculos en el mapa.';

  @override
  String get mapGettingLocation => 'Obteniendo ubicación...';

  @override
  String get mapLoadingMap => 'Cargando mapa...';

  @override
  String get mapLocationOffTitle => 'La ubicación está desactivada';

  @override
  String get mapLocationErrorTitle => 'Error de ubicación';

  @override
  String get mapLocationUnavailable => 'Ubicación temporalmente no disponible';

  @override
  String get mapLocationNoPermissionTitle => 'Haven no puede usar tu ubicación';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'La ubicación está desactivada en este dispositivo, así que Haven ha dejado de compartir tu ubicación con tus círculos. Actívala para volver a compartirla.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven ya no tiene permiso para usar tu ubicación, así que el uso compartido se ha detenido. Permite el acceso a la ubicación para reanudarlo.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'El permiso de ubicación de Haven está desactivado en los ajustes del sistema, así que el uso compartido se ha detenido. Actívalo ahí para reanudarlo.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven ha dejado de compartir tu ubicación. Activa la ubicación de este dispositivo y permite que Haven la use.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven ha dejado de recibir tu ubicación, así que el uso compartido se ha detenido. Comprueba que la ubicación está activada y que Haven tiene permiso para usarla.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Haven vuelve a tener acceso a tu ubicación. El uso compartido se ha reanudado.';

  @override
  String get clockSkewTitle => 'El reloj de este teléfono no está en hora';

  @override
  String get clockSkewBodyRejected =>
      'Tus círculos no están recibiendo tu ubicación, porque los relés rechazan la hora que marca este teléfono. Activa la fecha y la hora automáticas en los ajustes del sistema para solucionarlo.';

  @override
  String get clockSkewBodyBehind =>
      'Este teléfono va atrasado respecto a los demás miembros de tus círculos: tus ubicaciones se envían, pero caducan antes de tiempo y tus círculos pueden perderse algunas o todas. Activa la fecha y la hora automáticas en los ajustes del sistema para solucionarlo.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'El reloj ya está en hora. Haven vuelve a compartir tu ubicación.';

  @override
  String get clockSkewTitleDisagreement =>
      'Algún reloj de uno de tus círculos no está en hora';

  @override
  String get clockSkewBodyDisagreement =>
      'El reloj de este teléfono y el de otro miembro no coinciden: hay dos minutos o más de diferencia entre ellos. Si el que no está en hora es el de este teléfono, tus ubicaciones pueden caducar antes de que nadie las vea. Activa la fecha y la hora automáticas en los ajustes del sistema para descartar el de este teléfono.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'El aviso del reloj ha desaparecido.';

  @override
  String get sharingHealthTitleStopped =>
      'El uso compartido de ubicación se ha detenido';

  @override
  String get sharingHealthTitleNotSending =>
      'Tu ubicación no se está compartiendo';

  @override
  String get sharingHealthTitleNotReceiving =>
      'No estás recibiendo ubicaciones';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Sin actualizaciones desde hace aproximadamente $countString minutos',
      many:
          'Sin actualizaciones desde hace aproximadamente $countString minutos',
      one: 'Sin actualizaciones desde hace aproximadamente $countString minuto',
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
      other:
          'Sin actualizaciones desde hace aproximadamente $countString horas',
      many: 'Sin actualizaciones desde hace aproximadamente $countString horas',
      one: 'Sin actualizaciones desde hace aproximadamente $countString hora',
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
      other: 'Sin actualizaciones desde hace aproximadamente $countString días',
      many: 'Sin actualizaciones desde hace aproximadamente $countString días',
      one: 'Sin actualizaciones desde hace aproximadamente $countString día',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Reparar';

  @override
  String get sharingHealthRepairSent =>
      'Reparación enviada. Los demás se pondrán al día cuando sus teléfonos la reciban.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Ahora mismo no hay nada que reparar. Haven lo seguirá intentando.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'El uso compartido de ubicación sigue sin funcionar.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'El uso compartido de ubicación vuelve a funcionar.';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven no puede abrir este círculo ahora mismo';

  @override
  String get sharingHealthBodyQuarantined =>
      'Algo salió mal al cargar este círculo en este teléfono. El círculo sigue aquí.';

  @override
  String get sharingHealthTitleDisbanded => 'Este círculo ha terminado';

  @override
  String get sharingHealthBodyDisbanded =>
      'Una persona con el rol de Administrador puso fin a este círculo, así que ya no se comparte nada con él. Sal del círculo para quitarlo de este teléfono.';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'Haven vuelve a intentar cargar este círculo';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven sigue sin poder abrir este círculo.';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'Este círculo ha dejado de funcionar en este teléfono';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven ya no puede enviar ni recibir actualizaciones en este círculo desde este teléfono. Pide a alguna de las personas con el rol de Administrador del círculo que te quite y te vuelva a añadir. Si nadie puede, crea un círculo nuevo con las mismas personas.';

  @override
  String get sharingHealthTitleStalled =>
      'Haven no puede leer las actualizaciones de este círculo';

  @override
  String get sharingHealthBodyStalled =>
      'Parece que este teléfono se perdió un cambio en el círculo y no pudo encontrarlo en los relés. Pide a alguna de las personas con el rol de Administrador del círculo que te quite y te vuelva a añadir. Si nadie puede, crea un círculo nuevo con las mismas personas.';

  @override
  String get sharingHealthTitlePaused => 'Haven ha pausado este círculo';

  @override
  String get sharingHealthBodyCollision =>
      'Haven ha encontrado un problema con este círculo en este teléfono y ha dejado de compartir con él para mantener tu ubicación privada. Salir del círculo es la única forma de solucionarlo. Para volver a unirte, necesitarás una invitación nueva.';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven no ha podido comprobar este círculo en este teléfono, así que ha pausado el uso compartido con él para mantener tu ubicación privada. Volverá a comprobarlo por sí solo.';

  @override
  String get sharingHealthTitleLeaving => 'Estás saliendo de este círculo';

  @override
  String get sharingHealthBodyLeaving =>
      'No se comparte nada con este círculo mientras Haven termina de salir de él. Esto puede tardar aproximadamente un día. Cuando termine, el círculo desaparecerá de este teléfono.';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'Una eliminación que pediste no se llegó a hacer, así que Haven ha pausado el envío de tu ubicación a este círculo para que no la vea ninguna persona que intentaste quitar.';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'Una eliminación que pediste no se llegó a hacer, así que Haven ha pausado el envío de tu ubicación a este círculo para que no la vea ninguna persona que intentaste quitar. Abre la lista de miembros para ver quién sigue en el círculo.';

  @override
  String get sharingHealthBodyDepartureDue =>
      'Alguien ha salido de este círculo y su salida aún no se ha completado. Hasta que se complete, Haven no comparte tu ubicación con este círculo.';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'El uso compartido en segundo plano está en pausa para este círculo';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Los relés de este círculo cambiaron mientras Haven estaba en segundo plano. Haven termina de cambiarlos mientras está abierto; hasta entonces, este círculo no se comparte en segundo plano.';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'Un cambio en este círculo está esperando a que un relé lo confirme. Mientras tanto, Haven no envía tu ubicación a este círculo ni muestra las ubicaciones nuevas que lleguen de él. Haven sigue intentándolo mientras la app está abierta.';

  @override
  String get sharingHealthBodyAcknowledged =>
      'Un relé ha aceptado un cambio en este círculo y Haven lo está terminando. Hasta que termine, las actualizaciones de este círculo quedan en espera.';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'No se ha podido guardar un cambio en este círculo, así que no se ha enviado. Haven lo resuelve, como muy tarde, la próxima vez que se inicie; hasta entonces, las actualizaciones de este círculo quedan en espera.';

  @override
  String get sharingHealthBodyStoredInput =>
      'Este teléfono tiene actualizaciones de este círculo que aún no ha podido procesar. Hasta que lo haga, Haven no comparte tu ubicación con este círculo.';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven todavía está cerrando su última conexión, así que el uso compartido de ubicación está en pausa. Se reanudará en cuanto termine. Reiniciar tu teléfono siempre lo resuelve.';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'Haven vuelve a conectar con los relés, reintenta enviar tu ubicación y puede darle a este círculo claves de cifrado nuevas';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'El uso compartido de ubicación necesita atención en este círculo. Abre Detalles del círculo para ver por qué.';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return 'Algo sobre los cambios recientes en $circleName requiere tu atención. Abre los detalles de ese círculo para leerlo.';
  }

  @override
  String get circleDetailsAttentionTooltip =>
      'Detalles del círculo, necesita atención';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, necesita atención';
  }

  @override
  String get changeNoticeHeading => 'Cambios en este círculo';

  @override
  String get changeNoteRemovalUndone =>
      'Un cambio en este círculo no se llegó a aplicar. Si quitaba a alguien, cualquier persona que quitara sigue en el círculo y puede ver lo que se comparte en él.';

  @override
  String get changeNoteChangeUndone =>
      'Un cambio en este círculo no se llegó a aplicar, así que no ha cambiado nada. Si era tuyo y aún lo quieres, vuelve a hacerlo.';

  @override
  String get changeNoteMayBeOutOfStep =>
      'Puede que un cambio en este círculo haya llegado a los demás sin que este teléfono lo sepa, así que puede que este teléfono esté desincronizado respecto al resto.';

  @override
  String get changeNoteReinviteOwed =>
      'Alguien a quien invitaste figura en este círculo, pero no puede unirse porque Haven no puede enviarle la invitación. Quita a esa persona y vuelve a añadirla.';

  @override
  String get changeNoteChangeUnrecorded =>
      'No se ha podido guardar un cambio en este círculo, así que no se ha enviado.';

  @override
  String get changeNoteQueuedChangeDropped =>
      'Se ha cancelado un cambio pendiente en este círculo porque ya no se podía hacer como se pidió. Puede que ya se haya hecho de otra forma.';

  @override
  String get changeNoteQueuedChangesHeld =>
      'Algunos cambios en este círculo siguen pendientes.';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'Una eliminación que pediste en este círculo no se llegó a hacer. Cualquier persona que intentaste quitar podría seguir en el círculo.';

  @override
  String get changeNoteChangeWithdrawn =>
      'Un cambio de otra persona del círculo reemplazó a uno tuyo, así que el tuyo no se hizo. Si aún lo quieres, vuelve a hacerlo.';

  @override
  String get changeNoteWelcomeOwed =>
      'Una invitación a este círculo aún no se ha enviado. Haven sigue intentando enviarla mientras la app está abierta, durante un día como máximo desde que hiciste la invitación. Si para entonces la persona invitada no se ha unido, quítala y vuelve a añadirla.';

  @override
  String get changeNoteUnreadLocation =>
      'Algunas actualizaciones recientes enviadas a este círculo no se han podido abrir en este teléfono.';

  @override
  String get changeNoticeStillInCircleLabel => 'Todavía en el círculo:';

  @override
  String get changeNoticeRemoveAgain => 'Volver a quitar';

  @override
  String get changeNoticeReviewMembers => 'Revisar miembros';

  @override
  String get changeNoticeKeepMembers => 'Mantener en el círculo';

  @override
  String get changeNoticeKeepConfirmTitle => '¿Mantener en el círculo?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'Haven dejará de pausar el uso compartido con este círculo a causa de esta eliminación. Cualquier persona que intentaste quitar y que aún esté en el círculo se quedará en él y podrá ver tu ubicación cada vez que Haven la comparta con este círculo.';

  @override
  String get changeNoticeKeepConfirmAction => 'Mantener';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Última ubicación hace $countString minutos',
      many: 'Última ubicación hace $countString minutos',
      one: 'Última ubicación hace $countString minuto',
    );
    return '$_temp0';
  }

  @override
  String get mapThisLocation => 'esta ubicación';

  @override
  String get mapMemberFallbackName => 'miembro';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '¿Abrir $label en Apple Maps?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Solo se envía la coordenada del mapa a Apple Maps, nunca un nombre ni una identidad.';

  @override
  String get mapOpenInAppleMapsConfirm => 'Abrir en Apple Maps';

  @override
  String get mapOpenMapsError => 'No se pudo abrir Maps';

  @override
  String get mapControlsZoomIn => 'Acercar';

  @override
  String get mapControlsZoomOut => 'Alejar';

  @override
  String get mapControlsRecenter => 'Volver a centrar';

  @override
  String get mapControlsRecenterFab => 'Volver a centrar en mi ubicación';

  @override
  String get mapAttributionCreditsButton => 'Créditos y licencia del mapa';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'Marcador de tu ubicación$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Precisión: $metersString metros';
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
      other: 'hace $countString minutos',
      many: 'hace $countString minutos',
      one: 'hace $countString minuto',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'Marcador de miembro de $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'Marcador de miembro';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, visto por última vez $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name está fuera de pantalla hacia el $direction; toca para ver';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'Un miembro está fuera de pantalla hacia el $direction; toca para ver';
  }

  @override
  String get compassNorth => 'norte';

  @override
  String get compassNorthEast => 'noreste';

  @override
  String get compassEast => 'este';

  @override
  String get compassSouthEast => 'sureste';

  @override
  String get compassSouth => 'sur';

  @override
  String get compassSouthWest => 'suroeste';

  @override
  String get compassWest => 'oeste';

  @override
  String get compassNorthWest => 'noroeste';

  @override
  String get commonAdd => 'Añadir';

  @override
  String get addRelaySheetTitleInbox => 'Añadir relé de bandeja de entrada';

  @override
  String get addRelaySheetTitleKeyPackage => 'Añadir relé de KeyPackage';

  @override
  String get addRelaySheetTitleProfile => 'Añadir relé de perfil';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Pegar desde el portapapeles';

  @override
  String get addRelaySheetErrorEmpty => 'Introduce una dirección de relé.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Usa wss:// para que el tráfico a este relé esté cifrado.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'La URL del relé no debe contener credenciales.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'Introduce una dirección de relé como wss://relay.example.com.';

  @override
  String get avatarSemanticsLabel => 'Avatar de usuario';

  @override
  String avatarSemanticsFor(String initials) {
    return 'de $initials';
  }

  @override
  String get avatarSemanticsOnline => 'en línea';

  @override
  String get avatarSemanticsOffline => 'desconectado';
}
