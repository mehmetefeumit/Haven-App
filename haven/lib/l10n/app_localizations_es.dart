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
      'Haven no tiene servidor central. Tus mensajes cifrados viajan por servidores independientes llamados relés, y tú eliges cuáles usar. Ninguna empresa ni ningún gobierno puede apagar la red.';

  @override
  String get onboardingValueProp3Title => 'No necesitas cuenta';

  @override
  String get onboardingValueProp3Body =>
      'Sin correo, sin número de teléfono, sin registro. Haven crea una identidad cuya clave secreta nunca sale de tu teléfono, así que no hay ninguna cuenta que nadie pueda entregar.';

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
  String get locationSettingsErrorSnack => 'Algo salió mal';

  @override
  String get locationSettingsIntro =>
      'Haven comparte tu ubicación con tus círculos siempre que la app está abierta. Activa esto y tus círculos la seguirán viendo mientras Haven está en segundo plano. Si el sistema cierra Haven, tu ubicación deja de compartirse: en segundo plano, el sistema despierta Haven solo para recibir las ubicaciones de tus círculos, nunca para enviar la tuya. En Android, en cambio, tu ubicación se sigue compartiendo aunque deslices Haven fuera del selector de apps, y el envío de tu ubicación se reanuda por sí solo tras reiniciar el teléfono; en iPhone, ese envío sigue detenido hasta que abras Haven.';

  @override
  String get locationSettingsToggleTitle => 'Compartir en segundo plano';

  @override
  String get locationSettingsToggleSubtitle =>
      'Seguir compartiendo mientras Haven esté en segundo plano';

  @override
  String get locationSettingsIosLimitedNote =>
      'El uso compartido sigue funcionando en segundo plano con tu permiso actual. Configura la Ubicación de Haven como «Siempre» en Ajustes para que Haven también pueda ponerse al día con las ubicaciones de tus círculos después de que iOS cierre la app. Tu propio uso compartido solo se reanuda cuando vuelves a abrir Haven.';

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
      'Mientras compartir en segundo plano está activado, Haven mantiene una sesión de ubicación continua e iOS muestra un indicador azul en la barra de estado. Conceder «Siempre» permite además que Haven se ponga al día con tus círculos después de que iOS cierre la app.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Con licencia MIT';

  @override
  String aboutFooterVersion(String version) {
    return 'Versión $version';
  }

  @override
  String get privacyTitle => 'Privacidad';

  @override
  String get privacySubtitle =>
      'Cómo funciona Haven y qué pueden ver los demás';

  @override
  String get privacyHubSummary =>
      'Haven comparte tu ubicación solo con los grupos pequeños que tú eliges, llamados círculos, y la cifra en tu teléfono antes de que salga de él. No hay registro ni servidor de Haven. Son públicos el nombre visible y la foto que configuras, y también las claves y las listas de relés que los demás necesitan para invitarte. Las páginas siguientes explican eso, y todo lo demás, en lenguaje claro.';

  @override
  String get privacyGroupBasicsHeading => 'Lo básico';

  @override
  String get privacyMeansForYouLabel => 'Qué significa esto para ti';

  @override
  String get privacyMoreDetailLabel => 'Con más detalle';

  @override
  String get privacyMoreDetailExpandHint => 'Mostrar los detalles técnicos';

  @override
  String get privacyMoreDetailCollapseHint => 'Ocultar los detalles técnicos';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'Detalles técnicos mostrados';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Detalles técnicos ocultos';

  @override
  String get privacyWhatHavenIsTitle => 'Qué es Haven y por qué no hay cuenta';

  @override
  String get privacyWhatHavenIsSubtitle =>
      'Sin registro, sin servidor de empresa';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven comparte tu ubicación con grupos pequeños que tú eliges, llamados círculos. Detrás no hay ninguna cuenta. Nunca das una dirección de correo, un número de teléfono ni una contraseña.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven tampoco gestiona servidores propios. Tus actualizaciones de ubicación cifradas pasan por servidores independientes llamados relés, gestionados por otras personas. Los desarrolladores de Haven no pueden ver tu ubicación y no han puesto ningún rastreador en la app. Lo único que sí ven es cuánto se usa el mapa en total, porque las teselas del mapa se piden con una única clave compartida. Nunca ven quién las pidió.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'A ningún operador de relés se le puede obligar a entregar tu ubicación, porque los servidores por los que pasa esa ubicación no pueden leerla. El precio es que nadie puede restaurarte la identidad, y que todo lo que ya has publicado sigue publicado. Consulta «Tus dos claves» para saber qué respaldar.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'La app no contiene código de analíticas, informes de errores ni publicidad. Como Haven es de código abierto, eso se puede comprobar en lugar de tener que confiar en nuestra palabra.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven tampoco tiene notificaciones push, y es a propósito. Un servicio de notificaciones tendría que enterarse cada vez que alguien de tus círculos tuviera algo que entregarte, lo que revelaría más sobre tus hábitos que los propios relés.';

  @override
  String get privacyYourKeysTitle =>
      'Tus dos claves: una secreta y otra para compartir';

  @override
  String get privacyYourKeysSubtitle =>
      'Qué te identifica y qué debes respaldar';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'En lugar de un usuario y una contraseña, tienes un par de claves. La clave secreta demuestra que eres tú. La clave pública es la que usan los demás para encontrarte e invitarte.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Tu clave secreta se guarda solo en este teléfono, en un almacenamiento que protege el sistema operativo. Haven no la envía a ningún sitio: ni a un servidor, ni a nosotros.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Tu clave pública se puede dar sin riesgo. Funciona como un nombre de usuario que puedes publicar en cualquier parte. Compartirla no revela dónde estás.';

  @override
  String get privacyYourKeysMeansForYou =>
      'Para conservar esta identidad, haz una copia de seguridad. Ve a Ajustes → Identidad → Avanzado, toca «Mostrar clave secreta» y guárdala en un sitio seguro, por ejemplo en un gestor de contraseñas. Sin esa copia, perder el teléfono es perder la identidad para siempre.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Quien consiga tu clave secreta se convierte en ti. Podría unirse a círculos en tu nombre o publicar como si fueras tú. No la pegues nunca en otra app, en un mensaje ni en un sitio web.';

  @override
  String get privacyYourKeysDetailFormats =>
      'Ambas claves son secp256k1 y se muestran en los formatos habituales de Nostr: npub1… para la clave pública y nsec1… para la secreta. La firma ocurre dentro de la app, y la clave secreta se borra de las partes que la manejan directamente en cuanto se usa.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'Las claves que cifran los mensajes de tus círculos son distintas de esta clave de identidad y solo las tiene la app. Esa separación es deliberada: la clave que te nombra no es la clave que abre lo que enviaste.';

  @override
  String get privacyPublicProfileTitle => 'Tu nombre y tu foto son públicos';

  @override
  String get privacyPublicProfileSubtitle =>
      'Visibles para cualquiera, no solo para tus círculos';

  @override
  String get privacyPublicProfileIsPublic =>
      'El nombre visible y la foto que configuras se publican en Nostr, la red pública y abierta sobre la que funciona Haven. Cualquiera puede consultarlos, no solo las personas de tus círculos.';

  @override
  String get privacyPublicProfileOnSave =>
      'Tu nombre y tu foto se hacen públicos en el momento en que los guardas. No hay ningún ajuste que los mantenga privados, ni forma de compartir un nombre solo con tus círculos.';

  @override
  String get privacyPublicProfilePseudonym =>
      'Las instalaciones nuevas empiezan con un nombre inventado, como «Quiet Wanderer», que no dice nada de ti. Puedes conservarlo o cambiarlo por el que quieras.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Elige un nombre y una foto que no te importe mostrar en público. Si prefieres que no te reconozcan, conserva el nombre inventado que te dieron y no pongas foto.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Quitar tu foto más tarde no borra la copia que hay en el servidor. Haven sustituye tu perfil por uno vacío. El archivo de imagen sigue donde está alojado, y cualquier copia ya descargada sigue por ahí. Considera permanente todo lo que publiques.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'El perfil es un evento Nostr «kind 0» firmado con tu clave de identidad. Las fotos se suben a un alojamiento público de imágenes, blossom.primal.net, que ve la imagen, tu clave pública y tu dirección de red. Haven todavía no te deja elegir otro alojamiento.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Antes de subir la foto, Haven vuelve a codificarla y elimina los datos ocultos que añaden las cámaras, incluida la posición GPS donde se tomó la foto. Aquí eso importa: una foto de vacaciones podría, de lo contrario, llevar las coordenadas de tu casa.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'El camino de tu ubicación';

  @override
  String get privacyRelaysTitle =>
      'Los relés: los servidores que transmiten tus mensajes';

  @override
  String get privacyRelaysSubtitle =>
      'Los equipos de otras personas por los que pasan tus actualizaciones';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven no tiene servidor propio, así que tus actualizaciones viajan por los de otras personas. Se llaman relés: servidores pequeños e independientes que cualquiera puede gestionar. Un relé guarda brevemente un mensaje cifrado y lo entrega cuando tu círculo lo pide.';

  @override
  String get privacyRelaysWhyMany =>
      'Haven usa varios relés, así que ninguno puede dejarte aislado por su cuenta. Si uno se desconecta, los demás siguen funcionando. Tú eliges los relés por los que te llegan las invitaciones; los relés que usa un círculo quedan fijados al crearlo.';

  @override
  String get privacyRelaysYourLists =>
      'Haven mantiene tres listas para ti. Tus relés de bandeja de entrada son por donde te llegan las invitaciones, y tus relés de KeyPackage son donde los demás recogen las claves que necesitan para invitarte: Haven publica ambas listas para que otras personas puedan encontrarlas. Tus relés de perfil son distintos: ahí es donde se consultan y se publican tu nombre y tu foto, pero la lista en sí se queda en tu dispositivo y nunca se publica. Por eso, un relé que solo lleva tu tráfico de ubicación o tus invitaciones no tiene ninguna lista pública que le diga qué relés usas para tu perfil. Cada círculo lleva además su propia lista, y por ella viajan las actualizaciones cifradas del círculo.';

  @override
  String get privacyRelaysMeansForYou =>
      'Un relé nunca ve tu ubicación, porque se cifra antes de salir de tu teléfono. Sí ve lo que tiene que ser público para que otras personas puedan llegar hasta ti: las claves que los demás necesitan para invitarte y las listas que indican qué relés usar. Tu nombre y tu foto también son públicos, pero van a un conjunto de relés aparte. Haven te da desde el principio relés que funcionan, así que no tienes que cambiar nada.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Al margen de tus propias listas, Haven usa dos grupos de servidores públicos que tú no eliges: ocho para consultar los nombres y las fotos de otras personas, y seis para consultar las claves que hacen falta para invitarlas. Los dos grupos nunca se solapan. Puedes añadir tus propios servidores al grupo de perfil, pero no puedes sacar de él esos ocho. Haven contacta con ambos grupos aunque todos los relés que hayas elegido tú sean privados, y cada uno de esos servidores ve tu dirección de red.';

  @override
  String get privacyRelaysDetailProfileLookups =>
      'Para los nombres y las fotos, Haven pregunta por una sola persona cada vez. A cada persona se le asigna un servidor en tu dispositivo; si ese servidor no tiene nada sobre ella, Haven prueba con un segundo. Buscar a alguien expone a esa persona ante dos de los ocho servidores como máximo, nunca ante el grupo entero. Haven nunca redistribuye esas asignaciones por su cuenta, aunque sí se modifican si cambia el grupo de servidores. Así tus consultas se reparten, en lugar de ir todas a un mismo servidor. Aun así, cada servidor asignado va acumulando un registro duradero de que tu teléfono pregunta una y otra vez por una misma persona, y cuando las personas son pocas, varias de ellas pueden quedar asignadas al mismo servidor. Cuando guardas tu propio nombre o tu propia foto, eso se envía a todos los relés de perfil que estés usando —los ocho, menos los que Haven haya descartado y más los que hayas añadido tú—, y cada uno de ellos conoce así tu clave pública.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'Tu lista de relés de KeyPackage va firmada con tu clave de identidad y se publica en los relés que ya figuran en ella. Si añades ahí un relé privado, su dirección se vuelve pública y queda ligada a ti. No hay forma de mantener privado un relé que esté en esa lista.';

  @override
  String get privacyEncryptionTitle => 'Cómo funciona el cifrado';

  @override
  String get privacyEncryptionSubtitle =>
      'Una clave por círculo, y qué cambia cuando alguien entra o sale';

  @override
  String get privacyEncryptionPerCircle =>
      'Tu ubicación se cifra en tu teléfono antes de salir de él, con un estándar abierto llamado MLS. Cada círculo es su propio grupo cifrado con sus propias claves. Nadie fuera de un círculo puede leer lo que se envía dentro: ni un relé, ni Haven, ni otro círculo al que pertenezcas.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'Cuando alguien se une, el círculo pasa a una clave nueva. Esa persona puede leer lo que se envía después de su llegada, y nada de antes. Haven nunca envía a un miembro nuevo ubicaciones pasadas.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'Cuando alguien sale de un círculo, este pasa a otra clave nueva. Esa persona deja de poder leer nada nuevo en cuanto el resto del círculo se pone al día. Eso suele tardar unos minutos, y más si alguien estaba sin conexión en ese momento.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Salir de un círculo no recupera lo que sus miembros ya hayan guardado. Haven cambia las claves solo cuando alguien entra o sale, nunca según un temporizador. Por eso una sola clave puede cubrir semanas de mensajes, y todo lo que un miembro haya guardado en ese tiempo le sigue siendo legible. Aun así, no puede abrir nada de lo enviado después de su salida.';

  @override
  String get privacyEncryptionMeansForYou =>
      'El cifrado te protege de todos los que están fuera de tus círculos. No puede protegerte de quien alguna vez estuvo dentro. Para dejar de compartir con una persona en concreto, sal del círculo que compartes con ella y crea uno nuevo sin esa persona.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) es el mismo estándar del IETF que usan otras mensajerías seguras. Haven llega a la red Nostr a través del protocolo Marmot, que define cómo viajan los grupos MLS por los relés. La clave con la que firma cada círculo es distinta de tu clave pública de identidad de Nostr.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Cada periodo de clave se llama época, y un círculo pasa a una nueva solo cuando cambian sus miembros. Tu dispositivo guarda las claves de la época actual y de unas pocas recientes, las suficientes para abrir los mensajes que aún están llegando, y descarta el resto. Un círculo cuyos miembros no han cambiado en meses sigue en la época con la que empezó.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'Qué ven los miembros y qué ven los relés';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'Con quién compartes y los servidores que hay en medio';

  @override
  String get privacyWhatOthersSeeMembersHeading =>
      'Las personas de tus círculos';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Todos en un círculo ven tu ubicación exacta en el mapa, no una zona aproximada. No hay ningún ajuste que comparta una ubicación imprecisa con unos miembros y otra precisa con otros.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Mientras Haven está abierto y perteneces a un círculo, tu ubicación sale por sí sola cada dos o tres minutos. No hay botón de pausa: el interruptor de la página Ubicación solo decide si eso continúa mientras Haven está en segundo plano. Si el sistema cierra Haven, tu ubicación deja de compartirse. En Android, en cambio, tu ubicación se sigue compartiendo aunque deslices Haven fuera del selector de apps, y el envío de tu ubicación se reanuda por sí solo tras reiniciar el teléfono; en iPhone, ese envío sigue detenido hasta que abras Haven. Para dejar de compartir con un círculo, ábrelo y elige «Salir del círculo».';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Unirte a un círculo también muestra tu clave pública a todos sus miembros. Con ella pueden consultar tu perfil público y todo lo demás que hayas publicado alguna vez con esa clave.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Tu teléfono descarga la foto de perfil de cada miembro desde un servidor que ha elegido esa persona, sin que tú toques nada. Ese servidor ve entonces tu dirección de red, que te sitúa a grandes rasgos en el mapa. Una VPN lo oculta; nada más lo hace.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'Los operadores de relés';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Los relés, los servidores independientes por los que pasan tus actualizaciones, no pueden leer tu ubicación, tus mensajes, el nombre de tu círculo ni su lista de miembros. Tus actualizaciones de ubicación llevan una dirección de envío nueva y de un solo uso en lugar de tu clave pública. Tu perfil, tus invitaciones y tus listas de relés sí la llevan, así que un relé que gestione ambas cosas suele poder deducir que estás en un círculo, sin leer nada de lo que hay dentro.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'Sí ven tu dirección de red, cuándo estás en línea y el tamaño y la frecuencia de tu tráfico. Cada círculo lleva una etiqueta aleatoria. Con esa etiqueta, un relé puede agrupar los mensajes de un mismo círculo y estimar cuántas personas hay en él, sin llegar a saber quiénes son.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Únete a un círculo solo con personas a las que les darías la dirección de tu casa. Frente a los relés y a los de fuera, el cifrado aguanta, y una VPN oculta la dirección desde la que se conecta tu teléfono. Nada te protege de un miembro que hace una captura de pantalla.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'La etiqueta de un círculo se mantiene igual durante toda la vida de ese círculo, así que un relé puede vincular indefinidamente todos sus mensajes entre sí. El protocolo sí permite que un círculo pase a una etiqueta nueva, pero Haven no lo hace hoy por hoy, y cambiarla tampoco deshace lo que un relé ya haya vinculado.';

  @override
  String get commonLearnMore => 'Más información';

  @override
  String get relaySettingsBackendCaption =>
      'Haven no tiene servidor propio. Tus actualizaciones cifradas pasan por servidores independientes llamados relés, que no pueden leer tu ubicación ni tus mensajes.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'Esto depende de tu teléfono. En Android, Haven bloquea las capturas de pantalla y la grabación de pantalla en toda la app. En iPhone no puede: Haven difumina la vista previa del selector de apps, pero un miembro todavía puede capturar lo que hay en la pantalla.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven pide a los relés que descarten los mensajes de ubicación al cabo de unos cuatro minutos. Esa petición es solo orientativa: un relé puede quedarse con esos mensajes más tiempo. Solo los mensajes de ubicación llevan esa caducidad, así que un mensaje sin ella se reconoce a simple vista como un cambio de miembros y no como una actualización de ubicación. Las invitaciones no llevan ninguna caducidad y pueden quedarse indefinidamente en tu relé de bandeja de entrada.';

  @override
  String get privacyWhatOthersSeeDetailOnDevice =>
      'El teléfono de cada miembro deja de mostrar al cabo de un día la última ubicación que recibió de ti, y la borra la próxima vez que ese miembro abra Haven. Eso es aparte de lo que un miembro haya decidido guardar o capturar en pantalla por sí mismo, sobre lo que Haven no tiene ningún control.';

  @override
  String get privacyWhatOthersSeeDetailOneConnection =>
      'Haven abre una sola conexión con cada relé y la usa para todo lo que pasa por ese relé. Cuando un relé lleva tanto tus invitaciones como los mensajes de un círculo, esa única conexión pide a la vez las invitaciones dirigidas a tu propia clave pública y los mensajes de ese círculo por su etiqueta: eso es justo lo que le permite al relé vincular las dos cosas. En una instalación nueva, los mismos relés se usan para ambas cosas.';

  @override
  String get privacyGroupTheLimitsHeading => 'Los límites';

  @override
  String get privacyInferenceTitle => 'Lo que aún se puede deducir de ti';

  @override
  String get privacyInferenceSubtitle =>
      'Los rastros que el cifrado no puede ocultar';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'El cifrado oculta lo que envías. No puede ocultar que has enviado algo. Ese rastro que queda se llama metadatos: cuándo salió un mensaje, qué tamaño tenía y a qué servidores estabas conectado. Sigue a la vista aunque el contenido no lo esté.';

  @override
  String get privacyInferenceActivityPattern =>
      'A partir de ese rastro, un relé que uses puede deducir aproximadamente cuándo estás activo y con qué frecuencia. Mientras Haven está en pantalla —y, en el iPhone, mientras el uso compartido en segundo plano mantiene Haven en marcha—, la app envía además una actualización extra, como mucho una vez por minuto, cada vez que te mueves unos cien metros. A lo largo de varias horas, eso puede mostrarle a un relé si te estabas desplazando o si seguías en el mismo sitio. Ese rastro nunca muestra dónde estás.';

  @override
  String get privacyInferencePresence =>
      'Mientras Haven está funcionando mantiene una conexión abierta con tus relés. Pueden ver que estás en línea y qué etiquetas de círculo estás siguiendo, nunca el nombre de un círculo ni quién está en él. Es el precio de que las actualizaciones lleguen en segundos y no en minutos.';

  @override
  String get privacyInferenceIpHeading => 'Tu dirección de red';

  @override
  String get privacyInferenceIpAddress =>
      'Todos los servidores con los que habla Haven ven la dirección desde la que se conecta tu teléfono, su dirección IP: tus relés, el proveedor del mapa y quien aloje la foto de perfil de un miembro. Tu proveedor de internet ve a cuáles de esos servidores accediste y cuándo. Haven, por sí solo, no hace nada por ocultar ni lo uno ni lo otro.';

  @override
  String get privacyInferenceMapTilesHeading => 'El mapa en sí';

  @override
  String get privacyInferenceMapTiles =>
      'Para dibujar el mapa, Haven le pide al proveedor del mapa los cuadros de imagen que hay en pantalla, así que este deduce más o menos qué lugares miras. Haven también descarga por adelantado una pequeña zona alrededor de cada miembro que puedes ver, para que el mapa ya esté listo cuando te desplaces hasta allí: eso significa que el proveedor puede deducir más o menos dónde está tu círculo, y no solo hacia dónde miras tú. Esos cuadros se guardan en una caché cifrada de tu teléfono durante siete días como máximo, y se borran si eliminas tu identidad.';

  @override
  String get privacyInferenceVpnHeading => '¿Conviene usar una VPN?';

  @override
  String get privacyInferenceVpnHelps =>
      'Una VPN sustituye tu dirección por la suya, así que los relés y los demás servidores ya no ven desde dónde te conectas. También oculta a tu proveedor de internet a qué servidores accedes. Recomendamos Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'No es una solución milagrosa. Una VPN no cambia nada de lo que ven los miembros de tu círculo. Y no oculta el momento ni el tamaño de tu tráfico al relé con el que estás hablando. Además solo traslada tu confianza al proveedor de la VPN: no te libra de tener que confiar en alguien.';

  @override
  String get privacyInferenceMeansForYou =>
      '¿Te preocupa que los relés, tu proveedor de internet o los servidores del mapa te sitúen en un mapa? Una VPN es lo más útil que puedes añadir. ¿Te preocupan las personas de tus círculos? No te va a ayudar en absoluto.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven varía a propósito el intervalo entre actualizaciones, así que una grabación corta no muestra ningún ritmo claro. Promediada a lo largo de muchas horas, la frecuencia real sí se puede estimar. Los mensajes tampoco se rellenan para igualar su tamaño, y las actualizaciones de ubicación caen en un rango estrecho de tamaños, lo que las hace reconocibles como tales.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Dos cosas quedan más allá de cualquier decisión de diseño de esta app: alguien capaz de vigilar muchos relés a la vez, y tu propio teléfono en cuanto lo controla otra persona.';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Círculo \"$name\" creado. Invitaciones enviadas ($sentString de $totalString); la entrega del resto está pendiente.';
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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · época $epochString';
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
  String get leaveCircleDialogTitle => 'Salir del círculo';

  @override
  String get leaveCircleDialogBody =>
      '¿Salir de este círculo? Dejarás de enviar tu ubicación a sus miembros y de ver la suya. La última ubicación que enviaste se queda en sus teléfonos durante un día como máximo. Esto no se puede deshacer: necesitarías una invitación nueva para volver.';

  @override
  String get leaveCircleConfirm => 'Salir';

  @override
  String get leaveCircleIdentityUnavailable => 'Identidad no disponible';

  @override
  String get leaveCircleSuccess => 'Saliste del círculo correctamente';

  @override
  String get leaveCircleError => 'No se pudo salir del círculo';

  @override
  String get circleBlockedBannerTitle => 'Este círculo no se puede actualizar';

  @override
  String get circleBlockedBannerBody =>
      'Algo salió mal con el cifrado de este círculo, así que Haven ya no puede enviar ni recibir actualizaciones en él. Aún puedes ver más abajo la última información conocida, o salir del círculo.';

  @override
  String get legacyCircleBannerTitle => 'Este círculo debe volver a crearse';

  @override
  String get legacyCircleBannerBody =>
      'El motor de cifrado de Haven se actualizó, así que este círculo ya no se puede usar. Vuelve a crearlo para seguir compartiendo ubicación con las mismas personas. Tendrás que invitarlas de nuevo.';

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
      'Tu identidad y tu perfil público no han cambiado. No necesitas hacer nada con ellos.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Para mayor seguridad, debes volver a crear tus círculos y volver a invitar a sus miembros antes de poder compartir ubicación en ellos de nuevo.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Entendido';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven todavía está pidiendo a los relés que descarten algunos datos antiguos de la reciente actualización de seguridad.';

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
      'Foto actualizada. Publicada en tu perfil público de Nostr.';

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
      'Este teléfono va atrasado respecto a los demás miembros de tus círculos: tus ubicaciones se envían, pero caducan antes de que nadie pueda verlas. Activa la fecha y la hora automáticas en los ajustes del sistema para solucionarlo.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'El reloj ya está en hora. Haven vuelve a compartir tu ubicación.';

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
