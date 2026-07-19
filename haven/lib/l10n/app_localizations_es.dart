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
  String get onboardingValueProp1Body =>
      'Tu ubicación se cifra en tu dispositivo antes de salir, de modo que solo los círculos que elijas pueden leerla, nunca Haven ni nadie más. Como Haven es de código abierto, cualquiera puede verificarlo.';

  @override
  String get onboardingValueProp2Title => 'Nadie puede cerrarlo';

  @override
  String get onboardingValueProp2Body =>
      'Haven no tiene servidor central. Tus mensajes cifrados viajan a través de una red descentralizada de relés que tú mismo puedes elegir, así que ninguna entidad por sí sola puede cerrarlo.';

  @override
  String get onboardingValueProp3Title => 'No necesitas cuenta';

  @override
  String get onboardingValueProp3Body =>
      'Sin correo, sin número de teléfono, sin registro. Haven crea una identidad privada que vive solo en tu teléfono, sin nada que la vincule a la persona real que eres.';

  @override
  String get onboardingValueProp1Summary =>
      'Se cifra en tu dispositivo, así solo los círculos que elijas pueden leerla.';

  @override
  String get onboardingValueProp2Summary =>
      'Sin servidor central: funciona en una red de relés que tú eliges.';

  @override
  String get onboardingValueProp3Summary =>
      'Sin correo, teléfono ni registro. Nada te vincula con ella.';

  @override
  String get onboardingCreateIdentityTitle => 'Crea tu identidad';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven creará una identidad privada que vive solo en este teléfono. Así es como tus círculos te reconocen.';

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
  String get settingsIdentitySubtitle => 'Perfil, claves y compartir foto';

  @override
  String get settingsRelaysTitle => 'Relés';

  @override
  String get settingsRelaysSubtitle => 'Por dónde te llegan las invitaciones';

  @override
  String get settingsLocationTitle => 'Ubicación';

  @override
  String get settingsLocationSubtitle =>
      'Compartir en segundo plano y permisos';

  @override
  String get settingsMapStyleTitle => 'Estilo del mapa';

  @override
  String get settingsAppearanceSubtitle => 'Tema e idioma';

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
      'kind 10050, por donde te llegan las invitaciones';

  @override
  String get relaySettingsKeyPackageTitle => 'Mis relés de KeyPackage';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051, donde los invitados descubren tus claves de cifrado';

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
  String get relaySettingsExplainerSemantics =>
      'Cómo funcionan los relés de Haven';

  @override
  String get relaySettingsExplainerHeading => 'Cómo funciona';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven no tiene servidor central. Funciona sobre dos tecnologías abiertas. Nostr es una red de servidores independientes llamados relés que cualquiera puede gestionar; reciben tus mensajes, los guardan brevemente y los entregan cuando tus contactos los solicitan. Ningún relé es imprescindible, así que si uno se desconecta los demás siguen funcionando, y cualquier cosa que un relé pudiera verse obligado a entregar son siempre datos cifrados.';

  @override
  String get relaySettingsExplainerMarmot =>
      'El protocolo Marmot cifra tus mensajes en tu dispositivo antes de que salgan de él, usando el estándar MLS (Messaging Layer Security). Cada círculo es su propio grupo cifrado con sus propias claves, de modo que distintos círculos no pueden vincularse entre sí. Esas claves también siguen avanzando con el tiempo, una propiedad llamada confidencialidad hacia adelante, así que ni siquiera una clave expuesta más tarde puede desbloquear tus mensajes anteriores.';

  @override
  String get relaySettingsExplainerMetadata =>
      'Por eso, un relé nunca ve tu ubicación, tus mensajes, quién está en tus círculos ni tu identidad en esos mensajes. Cada mensaje se publica desde una dirección de envío nueva y de un solo uso, así que nada en el mensaje lo vincula a tu cuenta. Aun así, un relé sí ve algunos metadatos: una etiqueta aleatoria por círculo, el momento y el tamaño de tu tráfico, y la dirección de red desde la que te conectas.';

  @override
  String get relaySettingsExplainerInboxTerm =>
      'Los relés de bandeja de entrada';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' son tu buzón: donde se entregan, también cifradas, las invitaciones para unirte a un círculo, para que las recojas. Para que alguien pueda invitarte, debe poder alcanzar uno de estos relés.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'Los relés de KeyPackage';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' son donde publicas un pequeño paquete de tus claves públicas, que es seguro compartir. Alguien que conozca tu cuenta lo obtiene de estos relés para añadirte a un círculo.';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'Usar tu propio relé.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' Cada círculo también lleva su propia lista de relés, compartida con cada miembro al unirse; es esa lista, no tu bandeja de entrada, por donde viajan las actualizaciones cifradas continuas del círculo. Así que si prefieres evitar los relés públicos, puedes gestionar el tuyo y dirigir un círculo hacia él: una vez que todos se hayan unido, el tráfico de ese círculo puede fluir solo a través de él.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'El inconveniente es la accesibilidad.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' Cada miembro debe poder conectarse a ese relé y, cuando invitas a alguien por primera vez, ambos necesitáis un relé que los dos podáis alcanzar (por ejemplo, el mismo relé privado indicado como relé de bandeja de entrada y de KeyPackage de todos). Un relé privado ve el mismo tráfico cifrado y los mismos tiempos que cualquier otro; simplemente tú controlas quién lo gestiona.';

  @override
  String get relaySettingsExplainerFooter =>
      'Puedes añadir o quitar relés en cualquiera de las listas en cualquier momento. Más relés te hacen más fácil de localizar; menos te dan más control sobre dónde va tu tráfico cifrado.';

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
  String get locationSettingsErrorSnack => 'Algo salió mal';

  @override
  String get locationSettingsIntro =>
      'Cuando compartir en segundo plano está activado, tus círculos siguen viendo tu ubicación en directo incluso cuando Haven está cerrado.';

  @override
  String get locationSettingsToggleTitle => 'Compartir en segundo plano';

  @override
  String get locationSettingsToggleSubtitle =>
      'Seguir compartiendo cuando la app está cerrada';

  @override
  String get locationSettingsIosLimitedNote =>
      'Limitado en segundo plano. Configura la Ubicación de Haven como «Siempre» en Ajustes';

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
      'Para compartir en segundo plano de forma continua, configura la Ubicación de Haven como «Siempre» en Ajustes. iOS muestra un indicador azul en la barra de estado mientras una app usa tu ubicación en segundo plano.';

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
  String get aboutWhoCanSeeTitle => 'Quién puede ver qué';

  @override
  String get aboutWhoCanSeeIntro =>
      'Tu ubicación exacta solo la pueden leer las personas que tú elijas. Esto es lo que las principales partes pueden y no pueden ver.';

  @override
  String get aboutActorCirclesWho =>
      'Los miembros del círculo con quienes compartes';

  @override
  String get aboutActorCirclesSees =>
      'Tu ubicación exacta y el nombre visible que elijas, pero solo dentro de los círculos que compartes con ellos, nunca tus otros círculos.';

  @override
  String get aboutActorRelaysWho => 'Los operadores de relés';

  @override
  String get aboutActorRelaysSees =>
      'Los servidores que transmiten tus mensajes. Ven tu dirección IP, la clave pública con la que publicas (un identificador aleatorio, no tu nombre), el tamaño y el momento de tu tráfico, y qué cuenta buscaste al consultar a alguien. Nunca pueden leer tu ubicación, tus mensajes, los nombres de tus círculos ni quién está en ellos.';

  @override
  String get aboutActorMapWho => 'El proveedor del mapa (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'Solo mientras el mapa está abierto: tu dirección IP y la zona que estás viendo, para poder enviar las imágenes de mapa correctas. Nunca tus círculos ni tu ubicación compartida. Stadia anonimiza las direcciones IP y no vende tus datos.';

  @override
  String get aboutActorDevelopersWho => 'Los desarrolladores de Haven';

  @override
  String get aboutActorDevelopersSees =>
      'Nada. Haven no gestiona ningún servidor ni recopila analíticas. Un desarrollador solo podría ver lo que ve un operador de relés, y únicamente si usaste un relé que él gestione.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'Aun así, tu actividad no es invisible. Un relé que uses, o cualquiera que vigile tu red, puede deducir que estás activo, aproximadamente cuándo y con qué frecuencia, a partir de los tiempos de conexión y los tamaños de los mensajes.';

  @override
  String get aboutScreenshotTitle => 'Protección contra capturas de pantalla';

  @override
  String get aboutScreenshotBody =>
      'En Android, Haven bloquea las capturas de pantalla y la grabación de pantalla en toda la app para evitar exponer la ubicación por accidente. Es una protección a nivel de sistema (FLAG_SECURE) que se aplica a todas las pantallas de la app, incluidos el mapa y las listas de miembros.';

  @override
  String get aboutVpnTitle => 'Sé aún más privado con una VPN';

  @override
  String get aboutVpnBody =>
      'Los relés y el proveedor del mapa ven tu dirección IP, y tu proveedor de internet ve a qué servidores accedes. Una VPN de confianza les oculta tu dirección IP. Recomendamos Mullvad. No cambia lo que ven los miembros de tu círculo y traslada la confianza al proveedor de la VPN.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Con licencia MIT';

  @override
  String aboutFooterVersion(String version) {
    return 'Versión $version';
  }

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
  String get createCircleMemberAlreadyAdded => 'El miembro ya está añadido';

  @override
  String get createCircleNoIdInQr =>
      'No se encontró ningún ID válido en el código QR';

  @override
  String get createCircleNoAccountFound =>
      'No se encontró ninguna cuenta de Haven';

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
      'Todos en este círculo pueden ver la ubicación y el nombre visible de los demás. Tu nombre visible es el que configuras en Ajustes → Identidad. Este círculo permanece separado de cualquier otro en el que estés, así que sus miembros no pueden ver tus otros círculos ni quién está en ellos.';

  @override
  String get nameCircleCreateCta => 'Crear círculo';

  @override
  String get nameCircleStageCreatingGroup => 'Creando grupo seguro...';

  @override
  String get nameCircleStageSendingInvites => 'Enviando invitaciones...';

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
  String addMemberTitle(String circleName) {
    return 'Añadir a $circleName';
  }

  @override
  String get addMemberInfo =>
      'Los nuevos miembros pueden ver las ubicaciones cifradas de este círculo una vez que aceptan la invitación.';

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
  String addMemberPartialDelivery(int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Invitaciones enviadas ($sentString de $totalString). La entrega del resto está pendiente.';
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
  String get circleMemberInvitationPending => 'Invitación pendiente';

  @override
  String get circleMemberNoRecentLocation => 'Sin ubicación reciente';

  @override
  String get circleMemberRemoveTooltip => 'Quitar del círculo';

  @override
  String get circleMemberAdmin => 'Administrador';

  @override
  String get circleMemberHintPending => 'invitación pendiente';

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
  String get pendingMemberRemoveTooltip => 'Quitar miembro';

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
  String get pendingMemberNeedsUpdate => 'Necesita actualizar Haven';

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
  String get memberSearchAlreadyAdded => 'El miembro ya está añadido';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString más';
  }

  @override
  String get invitationStatusPending => 'Invitación pendiente';

  @override
  String get invitationStatusActive => 'Activa';

  @override
  String get invitationStatusDeclined => 'Rechazada';

  @override
  String invitationStatusSemantics(String label) {
    return 'Estado de la invitación: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Invitación para unirse a $circleName, invitado por $inviter, $countString miembros';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Invitado por el identificador criptográfico $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Invitado por: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
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
  String get circleDetailsRelaysHeading => 'Relés de este círculo';

  @override
  String get circleDetailsNoRelays => '(ninguno registrado)';

  @override
  String get circleDetailsRelaysNote =>
      'Estos relés se eligieron al crear el círculo y aún no son editables por el usuario. Son independientes de tus ajustes de relés personales.';

  @override
  String get circleDetailsAddMember => 'Añadir miembro';

  @override
  String get circleDetailsLeaveCircle => 'Salir del círculo';

  @override
  String get leaveCircleDialogTitle => 'Salir del círculo';

  @override
  String get leaveCircleDialogBody =>
      '¿Seguro que quieres salir de este círculo? Dejarás de recibir actualizaciones de ubicación de sus miembros. Esta acción no se puede deshacer.';

  @override
  String get leaveCircleConfirm => 'Salir';

  @override
  String get leaveCircleIdentityUnavailable => 'Identidad no disponible';

  @override
  String get leaveCircleSuccess => 'Saliste del círculo correctamente';

  @override
  String get leaveCircleError => 'No se pudo salir del círculo';

  @override
  String get leaveCircleAdminLimitationNote =>
      'Como administrador de este círculo, solo puedes salir una vez que todos los demás miembros se hayan ido. Sabemos que es un inconveniente — una futura actualización permitirá a los administradores transferir su rol y salir directamente.';

  @override
  String get circleBlockedBannerTitle => 'Este círculo no se puede actualizar';

  @override
  String get circleBlockedBannerBody =>
      'Algo salió mal con el cifrado de este círculo, así que Haven ya no puede enviar ni recibir actualizaciones en él. Aún puedes ver más abajo la última información conocida, o salir del círculo.';

  @override
  String get legacyCircleBannerTitle => 'Este círculo debe volver a crearse';

  @override
  String get legacyCircleBannerBody =>
      'El motor de cifrado de Haven se actualizó, así que este círculo ya no se puede usar. Vuelve a crearlo para seguir compartiendo ubicación con las mismas personas — tendrás que invitarlas de nuevo.';

  @override
  String get legacyCircleRecreateCta => 'Volver a crear círculo';

  @override
  String get legacyCircleRemoveCta => 'Quitar';

  @override
  String get legacyCircleRemoveDialogTitle => '¿Quitar círculo?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'Este círculo ya no se puede usar y se quitará de tu lista. Esto no afecta a ningún círculo nuevo que crees para reemplazarlo.';

  @override
  String get legacyCircleRemoveConfirm => 'Quitar';

  @override
  String get legacyCutoverExplainerTitle => 'Haven se ha actualizado';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Tu identidad y tu perfil público no han cambiado — no necesitas hacer nada con ellos.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Para mayor seguridad, debes volver a crear tus círculos y volver a invitar a sus miembros antes de poder compartir ubicación en ellos de nuevo.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Entendido';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven todavía está terminando de limpiar algunos datos de la reciente actualización de seguridad. Esto se completará automáticamente en cuanto vuelvas a estar en línea.';

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
      'Esto eliminará tu identidad de forma permanente. Asegúrate de haber respaldado tu clave secreta si quieres poder recuperarla.';

  @override
  String get identityAdvancedDeleteConfirm => 'Eliminar';

  @override
  String get identityAdvancedDeletedSnack => 'Identidad eliminada';

  @override
  String get identityAdvancedDeleteError =>
      'No se pudo eliminar la identidad. Inténtalo de nuevo.';

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
      'Tu clave pública funciona como un nombre de usuario que es seguro compartir. Las personas escanean este código, o pegan tu clave pública, para invitarte a un círculo. Compartirla no puede revelar tu ubicación, que solo es visible para los miembros de los círculos a los que te has unido, ni tu nombre y tu foto, que permanecen en este dispositivo a menos que elijas publicar un perfil público.';

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
  String keyDisplayCopiedToClipboard(String label) {
    return '$label copiado al portapapeles';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'mostrada';

  @override
  String get keyDisplayStateHidden => 'oculta';

  @override
  String get keyDisplayHideTooltip => 'Ocultar';

  @override
  String get keyDisplayRevealTooltip => 'Mostrar';

  @override
  String get keyDisplayCopyTooltip => 'Copiar';

  @override
  String get keyDisplayCompactCopied => 'Clave copiada al portapapeles';

  @override
  String get keyDisplayCompactTapToCopy => 'Toca para copiar';

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
      'Esto quita tu foto de tu perfil público.';

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
      'Foto actualizada — publicada en tu perfil público de Nostr.';

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
      other: 'hace $countString minutos',
      many: 'hace $countString minutos',
      one: 'hace $countString minuto',
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
      other: 'hace $countString horas',
      many: 'hace $countString horas',
      one: 'hace $countString hora',
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
      other: 'hace $countString días',
      many: 'hace $countString días',
      one: 'hace $countString día',
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
