// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appearanceTitle => 'Aparência';

  @override
  String get appearanceThemeHeader => 'Tema';

  @override
  String get appearanceThemeSystem => 'Padrão do sistema';

  @override
  String get appearanceThemeSystemSubtitle =>
      'Acompanhar as configurações do dispositivo';

  @override
  String get appearanceThemeLight => 'Claro';

  @override
  String get appearanceThemeLightSubtitle => 'Usar sempre o tema claro';

  @override
  String get appearanceThemeDark => 'Escuro';

  @override
  String get appearanceThemeDarkSubtitle => 'Usar sempre o tema escuro';

  @override
  String get appearanceLanguageTitle => 'Idioma';

  @override
  String get languageSystemDefault => 'Padrão do sistema';

  @override
  String get commonTryAgain => 'Tentar de novo';

  @override
  String get commonDismiss => 'Dispensar';

  @override
  String get commonSettings => 'Configurações';

  @override
  String get commonInvitations => 'Convites';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString convites pendentes',
      many: '$countString de convites pendentes',
      one: '1 convite pendente',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Voltar';

  @override
  String get commonContinue => 'Continuar';

  @override
  String get commonSkip => 'Pular';

  @override
  String get commonRetry => 'Tentar de novo';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Etapa $currentString de $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Compartilhe sua localização com privacidade, só com quem você quiser.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'só';

  @override
  String get onboardingWelcomeCta => 'Começar';

  @override
  String get onboardingValuePropsTitle => 'O que torna o Haven diferente';

  @override
  String get onboardingValueProp1Title => 'Só os seus círculos podem ver você';

  @override
  String get onboardingValueProp1Body =>
      'Sua localização é criptografada no seu dispositivo antes de sair dele, então só os círculos que você escolher podem lê-la, nunca o Haven nem ninguém mais. Como o Haven é de código aberto, qualquer pessoa pode verificar isso.';

  @override
  String get onboardingValueProp2Title => 'Ninguém pode desligá-lo';

  @override
  String get onboardingValueProp2Body =>
      'O Haven não tem servidor central. Suas mensagens criptografadas trafegam por uma rede descentralizada de relays que você mesmo pode escolher, então nenhuma entidade isolada pode desligá-lo.';

  @override
  String get onboardingValueProp3Title => 'Não precisa de conta';

  @override
  String get onboardingValueProp3Body =>
      'Sem e-mail, sem telefone, sem cadastro. O Haven cria uma identidade privada que existe só no seu celular, sem nada que a ligue à sua pessoa real.';

  @override
  String get onboardingCreateIdentityTitle => 'Crie sua identidade';

  @override
  String get onboardingCreateIdentityBody =>
      'O Haven vai criar uma identidade privada que existe só neste celular. É assim que os seus círculos reconhecem você.';

  @override
  String get onboardingCreateIdentityWarning =>
      'Se você perder este celular ou apagar o app, sua identidade desaparece. O Haven não tem como recuperá-la para você.';

  @override
  String get onboardingCreateIdentityCta => 'Criar minha identidade';

  @override
  String get onboardingCreateIdentityLoading => 'Preparando tudo…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'Já tem uma chave?';

  @override
  String get onboardingCreateIdentityImportLink => 'Importe-a em vez disso';

  @override
  String get onboardingCreateIdentityError =>
      'Algo deu errado ao criar sua identidade. Tente de novo.';

  @override
  String get onboardingImportTitle => 'Importe sua chave existente';

  @override
  String get onboardingImportBody =>
      'Cole a chave secreta que você guardou de outro app compatível com o Haven.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'Importar';

  @override
  String get onboardingImportLoading => 'Importando…';

  @override
  String get onboardingImportInvalid =>
      'Isso não parece ser uma chave de backup válida. Confira e tente de novo.';

  @override
  String get onboardingImportError =>
      'Não foi possível importar essa chave. Confira e tente de novo.';

  @override
  String get onboardingDisplayNameTitle => 'Escolha um nome';

  @override
  String get onboardingDisplayNameBody =>
      'Este nome só é visível para as pessoas cujos convites de círculo você aceitar. Os convites são enviados usando uma chave pública, então seu nome fica oculto até você aceitar.';

  @override
  String get onboardingDisplayNameHint => 'ex.: Alex';

  @override
  String get onboardingDisplayNameError =>
      'Não foi possível salvar esse nome. Tente de novo.';

  @override
  String get onboardingReadyTitle => 'Tudo pronto';

  @override
  String get onboardingReadyBody =>
      'O Haven é organizado em círculos, que são grupos pequenos e privados onde você compartilha sua localização com pessoas em quem confia. Crie seu primeiro círculo ou aguarde um convite de alguém que você conhece.';

  @override
  String get onboardingReadyCta => 'Entrar no Haven';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonOpenSettings => 'Abrir configurações';

  @override
  String get settingsTitle => 'Configurações';

  @override
  String get settingsIdentityTitle => 'Identidade';

  @override
  String get settingsIdentitySubtitle =>
      'Perfil, chaves e compartilhamento de foto';

  @override
  String get settingsRelaysTitle => 'Relays';

  @override
  String get settingsRelaysSubtitle => 'Onde os convites chegam até você';

  @override
  String get settingsLocationTitle => 'Localização';

  @override
  String get settingsLocationSubtitle =>
      'Compartilhamento em segundo plano e permissões';

  @override
  String get settingsMapStyleTitle => 'Estilo do mapa';

  @override
  String get settingsAppearanceSubtitle => 'Tema e idioma';

  @override
  String get settingsAboutTitle => 'Sobre';

  @override
  String get settingsDebugOverlayTitle => 'Sobreposição de log de depuração';

  @override
  String get settingsDebugOverlaySubtitle => 'Mostrar a saída de log na tela';

  @override
  String get relaySettingsTitle => 'Relays';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Verificar relays';

  @override
  String get relaySettingsNoIdentityTitle => 'Sem identidade';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Crie uma identidade primeiro para gerenciar os relays.';

  @override
  String get relaySettingsLoadIdentityError =>
      'Falha ao carregar a identidade.';

  @override
  String get relaySettingsInboxTitle => 'Meus relays de caixa de entrada';

  @override
  String get relaySettingsInboxSubtitle =>
      'kind 10050, onde os convites chegam até você';

  @override
  String get relaySettingsKeyPackageTitle => 'Meus relays de KeyPackage';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051, onde os convidados descobrem suas chaves de criptografia';

  @override
  String get relaySettingsLoadRelaysError => 'Falha ao carregar os relays.';

  @override
  String get relaySettingsAddRelay => 'Adicionar relay';

  @override
  String get relaySettingsRestoreDefaults => 'Restaurar padrões';

  @override
  String get relaySettingsAddRelayError => 'Falha ao adicionar o relay.';

  @override
  String get relaySettingsRemoveRelayError => 'Falha ao remover o relay.';

  @override
  String get relaySettingsRestoreTitle => 'Restaurar os relays padrão?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Seus $countString relays atuais serão substituídos pelos padrões do Haven. Isso não pode ser desfeito.',
      many:
          'Seus $countString de relays atuais serão substituídos pelos padrões do Haven. Isso não pode ser desfeito.',
      one:
          'Seu relay atual será substituído pelos padrões do Haven. Isso não pode ser desfeito.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Restaurar';

  @override
  String get relaySettingsRestoreSuccess => 'Padrões restaurados.';

  @override
  String get relaySettingsRestoreError => 'Falha ao restaurar os padrões.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'Remover $url';
  }

  @override
  String get relaySettingsStatusConnected => 'Conectado';

  @override
  String get relaySettingsStatusChecking => 'Verificando';

  @override
  String get relaySettingsStatusUnreachable => 'Inacessível';

  @override
  String get relaySettingsStatusNotChecked => 'Não verificado';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'Status do relay: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'Nenhum relay configurado';

  @override
  String get relaySettingsEmptyMessage =>
      'Você precisa de pelo menos um relay para que outras pessoas possam alcançar você. Toque abaixo para restaurar os padrões do Haven.';

  @override
  String get relaySettingsExplainerSemantics =>
      'Como funcionam os relays do Haven';

  @override
  String get relaySettingsExplainerHeading => 'Como isso funciona';

  @override
  String get relaySettingsExplainerNostr =>
      'O Haven não tem servidor central. Ele funciona com base em duas tecnologias abertas. O Nostr é uma rede de servidores independentes chamados relays que qualquer pessoa pode operar; eles recebem suas mensagens, guardam-nas por pouco tempo e as repassam quando seus contatos as solicitam. Nenhum relay isolado é essencial, então, se um sair do ar, os outros continuam funcionando, e tudo o que um relay poderia ser forçado a entregar é apenas dado criptografado.';

  @override
  String get relaySettingsExplainerMarmot =>
      'O protocolo Marmot criptografa suas mensagens no seu dispositivo antes de elas saírem dele, usando o padrão MLS (Messaging Layer Security). Cada círculo é seu próprio grupo criptografado, com suas próprias chaves, então círculos diferentes não podem ser vinculados entre si. Essas chaves também continuam avançando ao longo do tempo, uma propriedade chamada sigilo futuro, então mesmo uma chave exposta mais tarde não consegue desbloquear suas mensagens anteriores.';

  @override
  String get relaySettingsExplainerMetadata =>
      'Por causa disso, um relay nunca vê sua localização, suas mensagens, quem está nos seus círculos nem sua identidade nessas mensagens. Cada mensagem é publicada a partir de um endereço de envio novo e de uso único, então nada na mensagem a liga à sua conta. Mesmo assim, um relay ainda vê alguns metadados: uma etiqueta aleatória por círculo, o momento e o tamanho do seu tráfego e o endereço de rede de onde você se conecta.';

  @override
  String get relaySettingsExplainerInboxTerm => 'Relays de caixa de entrada';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' são sua caixa de correio: onde os convites para entrar em um círculo, eles próprios criptografados, são entregues para você recolher. Para alguém convidar você, essa pessoa precisa conseguir alcançar um desses relays.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'Relays de KeyPackage';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' são onde você publica um pequeno conjunto das suas chaves públicas, que é seguro compartilhar. Alguém que conhece sua conta o busca nesses relays para adicionar você a um círculo.';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'Usando seu próprio relay.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' Cada círculo também carrega sua própria lista de relays, compartilhada com cada membro quando ele entra; é por essa lista, e não pela sua caixa de entrada, que viajam as atualizações criptografadas contínuas do círculo. Então, se você preferir evitar relays públicos, pode operar o seu próprio e apontar um círculo para ele: depois que todos tiverem entrado, o tráfego desse círculo pode fluir somente por ele.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'O detalhe é a acessibilidade.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' Cada membro precisa conseguir se conectar a esse relay e, quando você convida alguém pela primeira vez, vocês dois precisam de um relay que ambos consigam alcançar (por exemplo, o mesmo relay privado listado como relay de caixa de entrada e de KeyPackage de todos). Um relay privado ainda vê o mesmo tráfego criptografado e o mesmo momento de envio que qualquer outro; você apenas controla quem o opera.';

  @override
  String get relaySettingsExplainerFooter =>
      'Você pode adicionar ou remover relays de qualquer uma das listas a qualquer momento. Mais relays tornam você mais fácil de alcançar; menos relays dão a você mais controle sobre para onde vai seu tráfego criptografado.';

  @override
  String get locationSettingsTitle => 'Localização';

  @override
  String get locationSettingsDisabledSnack =>
      'Compartilhamento em segundo plano desativado';

  @override
  String get locationSettingsEnabledSnack =>
      'Compartilhamento em segundo plano ativado';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'O compartilhamento em segundo plano precisa de uma notificação para o Android mantê-lo em execução. Por enquanto está desativado. Ative as notificações do Haven para ligá-lo.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'Ativado. A otimização de bateria pode pausar o compartilhamento em alguns celulares. Exclua o Haven da otimização de bateria para mantê-lo confiável.';

  @override
  String get locationSettingsErrorSnack => 'Algo deu errado';

  @override
  String get locationSettingsIntro =>
      'Quando o compartilhamento em segundo plano está ativado, seus círculos continuam vendo sua localização ao vivo mesmo com o Haven fechado.';

  @override
  String get locationSettingsToggleTitle => 'Compartilhar em segundo plano';

  @override
  String get locationSettingsToggleSubtitle =>
      'Continuar compartilhando com o app fechado';

  @override
  String get locationSettingsIosLimitedNote =>
      'Limitado em segundo plano. Defina a Localização como \"Sempre\" para o Haven nos Ajustes';

  @override
  String get locationSettingsAndroidHeader =>
      'Configurações do sistema para mais confiabilidade';

  @override
  String get locationSettingsAndroidNotification =>
      'O Haven precisa de uma notificação persistente para o Android manter o serviço em segundo plano ativo. Se você negou a permissão de notificação, abra as Configurações e permita notificações para o Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'Para um compartilhamento em segundo plano confiável, exclua também o Haven da otimização de bateria. Vá em Configurações → Apps → Haven → Bateria → Permitir o tempo todo.';

  @override
  String get locationSettingsAndroidVendors =>
      'Em aparelhos Samsung, remova o Haven dos \"Apps em suspensão\" (Cuidados com o dispositivo → Bateria → Limites de uso em segundo plano). Na Xiaomi, ative a Inicialização automática para o Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'Para compartilhamento contínuo em segundo plano, defina a Localização como \"Sempre\" para o Haven nos Ajustes. O iOS mostra um indicador azul na barra de status enquanto um app está usando sua localização em segundo plano.';

  @override
  String get mapStyleTitle => 'Estilo do mapa';

  @override
  String get mapStyleMinimalTitle => 'Minimalista';

  @override
  String get mapStyleMinimalSubtitle =>
      'Tela tranquila e com poucos detalhes que acompanha seu tema claro ou escuro';

  @override
  String get mapStyleDetailedTitle => 'Detalhado';

  @override
  String get mapStyleDetailedSubtitle =>
      'Ruas, rótulos e lugares em cores plenas';

  @override
  String get mapStyleOutdoorsTitle => 'Ar livre';

  @override
  String get mapStyleOutdoorsSubtitle =>
      'Terreno sombreado com trilhas e parques';

  @override
  String get mapStylePreviewHeader => 'Prévia';

  @override
  String get mapStylePreviewCity => 'Cidade';

  @override
  String get mapStylePreviewNature => 'Natureza';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Prévia do mapa ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Prévia do mapa indisponível nesta versão';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'A prévia ao vivo aparece nas versões de lançamento';

  @override
  String get aboutTitle => 'Sobre';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'Compartilhamento de localização privado e resistente à censura.';

  @override
  String get aboutLicensesTitle => 'Licenças de código aberto';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'Relatar um problema no mapa';

  @override
  String get aboutSupportOsm => 'Apoiar o OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nDados do mapa licenciados sob a ODbL';

  @override
  String get aboutLinkOpenError => 'Não foi possível abrir o link';

  @override
  String get aboutWhoCanSeeTitle => 'Quem pode ver o quê';

  @override
  String get aboutWhoCanSeeIntro =>
      'Sua localização exata só pode ser lida pelas pessoas que você escolher. Veja a seguir o que as principais partes podem e não podem ver.';

  @override
  String get aboutActorCirclesWho =>
      'Os membros do círculo com quem você compartilha';

  @override
  String get aboutActorCirclesSees =>
      'Sua localização exata e o nome de exibição que você escolher, mas apenas dentro dos círculos que você compartilha com eles, nunca os seus outros círculos.';

  @override
  String get aboutActorRelaysWho => 'Os operadores dos relays';

  @override
  String get aboutActorRelaysSees =>
      'Os servidores que repassam suas mensagens. Eles veem seu endereço IP, a chave pública sob a qual você publica (um ID aleatório, não o seu nome), o tamanho e o momento do seu tráfego e qual conta você procurou ao buscar alguém. Eles nunca conseguem ler sua localização, suas mensagens, os nomes dos seus círculos nem quem está neles.';

  @override
  String get aboutActorMapWho => 'O provedor do mapa (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'Apenas enquanto o mapa está aberto: seu endereço IP e a área que você está visualizando, para que ele possa enviar as imagens corretas do mapa. Nunca seus círculos nem sua localização compartilhada. A Stadia anonimiza os endereços IP e não vende seus dados.';

  @override
  String get aboutActorDevelopersWho => 'Os desenvolvedores do Haven';

  @override
  String get aboutActorDevelopersSees =>
      'Nada. O Haven não opera servidores e não coleta análises. Um desenvolvedor só poderia ver o que um operador de relay vê, e apenas se você usasse um relay que ele por acaso operasse.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'Ainda assim, sua atividade não é invisível. Um relay que você usa, ou qualquer pessoa observando sua rede, pode perceber que você está ativo, mais ou menos quando e com que frequência, a partir do momento das conexões e do tamanho das mensagens.';

  @override
  String get aboutScreenshotTitle => 'Proteção contra capturas de tela';

  @override
  String get aboutScreenshotBody =>
      'No Android, o Haven bloqueia capturas de tela e gravação de tela em todo o app para evitar a exposição acidental da localização. Trata-se de uma proteção em nível de sistema (FLAG_SECURE) que se aplica a todas as telas do app, incluindo o mapa e as listas de membros.';

  @override
  String get aboutVpnTitle => 'Tenha mais privacidade com uma VPN';

  @override
  String get aboutVpnBody =>
      'Os relays e o provedor do mapa veem seu endereço IP, e seu provedor de internet vê quais servidores você acessa. Uma VPN confiável oculta seu endereço IP deles. Recomendamos a Mullvad. Ela não muda o que os membros do seu círculo veem, e transfere a confiança para o provedor da VPN.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Licenciado sob a MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Versão $version';
  }

  @override
  String get commonClearAll => 'Limpar tudo';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString membros',
      many: '$countString de membros',
      one: '1 membro',
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
  String get circlesRefreshTooltip => 'Atualizar círculos';

  @override
  String get circlesRequiresIdentity =>
      'Criar um círculo exige antes a configuração da identidade';

  @override
  String get circlesCreateCta => 'Criar círculo';

  @override
  String get circlesYourCircles => 'Seus círculos';

  @override
  String get circlesEmptyTitle => 'Nenhum círculo ainda';

  @override
  String get circlesEmptyMessage =>
      'Crie um círculo para começar a compartilhar sua localização com amigos e familiares de confiança.';

  @override
  String get circlesSheetEmptyMessage =>
      'Crie um círculo para começar a compartilhar sua localização com contatos de confiança.';

  @override
  String get circlesLoadError => 'Não foi possível carregar os círculos';

  @override
  String get circlesSelectToView => 'Selecione um círculo para ver os membros';

  @override
  String get circlesNoMembers => 'Nenhum membro neste círculo';

  @override
  String get createCircleTitle => 'Adicionar membros';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Selecionados ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Adicione membros ao círculo';

  @override
  String get createCircleEmptyMessage =>
      'Pesquise por ID ou escaneie o QR code para adicionar membros.';

  @override
  String get createCircleNoValidMembers => 'Nenhum membro válido para convidar';

  @override
  String get createCircleMemberAlreadyAdded => 'Membro já adicionado';

  @override
  String get createCircleNoIdInQr => 'Nenhum ID válido encontrado no QR code';

  @override
  String get createCircleNoAccountFound => 'Nenhuma conta do Haven encontrada';

  @override
  String get createCircleCouldNotVerify =>
      'Não foi possível verificar o membro';

  @override
  String get createCircleSomethingWentWrong => 'Algo deu errado';

  @override
  String get nameCircleTitle => 'Dê um nome ao seu círculo';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString membros serão convidados',
      many: '$countString de membros serão convidados',
      one: '1 membro será convidado',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Nome do círculo';

  @override
  String get nameCircleNameHint => 'ex.: Família, Amigos próximos';

  @override
  String get nameCircleNameEmptyError => 'Informe um nome para o círculo';

  @override
  String get nameCircleNameTooLongError =>
      'O nome deve ter no máximo 50 caracteres';

  @override
  String get nameCircleSharingInfo =>
      'Todos neste círculo podem ver a localização e o nome de exibição uns dos outros. Seu nome de exibição é o que você definiu em Configurações → Identidade. Este círculo permanece separado de quaisquer outros dos quais você participa, então seus membros não podem ver seus outros círculos nem quem está neles.';

  @override
  String get nameCircleCreateCta => 'Criar círculo';

  @override
  String get nameCircleStageCreatingGroup => 'Criando o grupo seguro...';

  @override
  String get nameCircleStageSendingInvites => 'Enviando os convites...';

  @override
  String get nameCircleStageComplete => 'Concluído!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Progresso da criação: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString por cento concluído';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Círculo \"$name\" criado! $countString convites enviados.',
      many: 'Círculo \"$name\" criado! $countString de convites enviados.',
      one: 'Círculo \"$name\" criado! 1 convite enviado.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Erro de identidade. Verifique a configuração da sua identidade.';

  @override
  String get nameCircleCreateError =>
      'Falha ao criar o círculo. Tente de novo.';

  @override
  String addMemberTitle(String circleName) {
    return 'Adicionar a $circleName';
  }

  @override
  String get addMemberInfo =>
      'Os novos membros poderão ver as localizações criptografadas deste círculo assim que aceitarem o convite.';

  @override
  String get addMemberAlreadyInCircle => 'Já está neste círculo';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Enviar convites',
      many: 'Enviar convites',
      one: 'Enviar convite',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Enviando convites...',
      many: 'Enviando convites...',
      one: 'Enviando convite...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Convites enviados para $circleName',
      many: 'Convites enviados para $circleName',
      one: 'Convite enviado para $circleName',
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

    return 'Convites enviados ($sentString de $totalString). Entrega pendente para os demais.';
  }

  @override
  String get addMemberError => 'Falha ao adicionar o membro. Tente de novo.';

  @override
  String get qrScannerTitle => 'Escanear QR code';

  @override
  String get qrScannerToggleFlash => 'Alternar flash';

  @override
  String get qrScannerSwitchCamera => 'Trocar de câmera';

  @override
  String get qrScannerInstruction => 'Posicione o QR code dentro do quadro';

  @override
  String get qrScannerScanning => 'Escaneando...';

  @override
  String get circleMemberInvitationPending => 'Convite pendente';

  @override
  String get circleMemberNoRecentLocation => 'Sem localização recente';

  @override
  String get circleMemberRemoveTooltip => 'Remover do círculo';

  @override
  String get circleMemberAdmin => 'Admin';

  @override
  String get circleMemberHintPending => 'convite pendente';

  @override
  String get circleMemberHintNoLocation => 'nenhuma localização disponível';

  @override
  String get circleMemberHintMember => 'membro';

  @override
  String get circleMemberHintTapToCenter =>
      'toque para centralizar o mapa na localização da pessoa';

  @override
  String get pendingMemberRetryTooltip => 'Tentar validar de novo';

  @override
  String get pendingMemberRemoveTooltip => 'Remover membro';

  @override
  String get pendingMemberValidating => 'Validando';

  @override
  String get pendingMemberValid => 'Válido';

  @override
  String get pendingMemberWarning => 'Aviso';

  @override
  String get pendingMemberCheckingAvailability =>
      'Verificando disponibilidade...';

  @override
  String get pendingMemberReadyToInvite => 'Pronto para convidar';

  @override
  String get memberSearchHint => 'Digite o ID do membro...';

  @override
  String get memberSearchPasteTooltip => 'Colar da área de transferência';

  @override
  String get memberSearchAddTooltip => 'Adicionar membro';

  @override
  String get memberSearchScanTooltip => 'Escanear QR code';

  @override
  String get memberSearchHelper =>
      'Peça aos contatos o QR code ou o ID do Haven deles';

  @override
  String get memberSearchNoValidId => 'Nenhum ID do Haven válido encontrado';

  @override
  String get memberSearchAlreadyAdded => 'Membro já adicionado';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString a mais';
  }

  @override
  String get invitationStatusPending => 'Convite pendente';

  @override
  String get invitationStatusActive => 'Ativo';

  @override
  String get invitationStatusDeclined => 'Recusado';

  @override
  String invitationStatusSemantics(String label) {
    return 'Status do convite: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Convite para entrar em $circleName, enviado por $inviter, $countString membros';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Convidado pelo identificador criptográfico $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Convidado por: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString membros',
      many: '$countString de membros',
      one: '1 membro',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'Agora mesmo';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'há ${countString}d';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'há ${countString}h';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'há ${countString}m';
  }

  @override
  String get invitationCardDecline => 'Recusar';

  @override
  String get invitationCardAccept => 'Aceitar';

  @override
  String get invitationAcceptedSnack => 'Convite aceito';

  @override
  String get invitationDeclinedSnack => 'Convite recusado';

  @override
  String get invitationAcceptError =>
      'Falha ao aceitar o convite. Tente de novo.';

  @override
  String get invitationDeclineError =>
      'Falha ao recusar o convite. Tente de novo.';

  @override
  String get circleSelectorLabel => 'Seletor de círculo';

  @override
  String get circleSelectorPlaceholder => 'Selecione um círculo';

  @override
  String get circleSelectorNewCircle => 'Novo círculo';

  @override
  String get circleSelectorLoadError => 'Falha ao carregar os círculos';

  @override
  String get circleSelectorExpandedAnnouncement =>
      'Lista de círculos expandida';

  @override
  String get circleSelectorCollapsedAnnouncement =>
      'Lista de círculos recolhida';

  @override
  String get circleDetailsButtonTooltip => 'Detalhes do círculo';

  @override
  String get circleDetailsTitle => 'Detalhes do círculo';

  @override
  String get circleDetailsRelaysHeading => 'Relays deste círculo';

  @override
  String get circleDetailsNoRelays => '(nenhum registrado)';

  @override
  String get circleDetailsRelaysNote =>
      'Esses relays foram escolhidos quando este círculo foi criado e ainda não podem ser editados pelo usuário. São independentes das suas configurações pessoais de relays.';

  @override
  String get circleDetailsAddMember => 'Adicionar membro';

  @override
  String get circleDetailsLeaveCircle => 'Sair do círculo';

  @override
  String get leaveCircleDialogTitle => 'Sair do círculo';

  @override
  String get leaveCircleDialogBody =>
      'Tem certeza de que quer sair deste círculo? Você deixará de receber as atualizações de localização dos seus membros. Esta ação não pode ser desfeita.';

  @override
  String get leaveCircleConfirm => 'Sair';

  @override
  String get leaveCircleIdentityUnavailable => 'Identidade indisponível';

  @override
  String get leaveCircleSuccess => 'Você saiu do círculo';

  @override
  String get leaveCircleError => 'Falha ao sair do círculo';

  @override
  String get circlesPanelCollapsedAnnouncement =>
      'Painel de círculos recolhido';

  @override
  String get circlesPanelExpandedAnnouncement => 'Painel de círculos expandido';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'Painel de círculos levemente aberto';

  @override
  String get circlesPanelHalfOpenAnnouncement =>
      'Painel de círculos meio aberto';

  @override
  String get circleMemberAnnouncementSelf => 'você';

  @override
  String get circleMemberAnnouncementFallback => 'membro';

  @override
  String get invitationsRefreshTooltip => 'Atualizar convites';

  @override
  String get invitationsLoadError => 'Não foi possível carregar os convites';

  @override
  String get invitationsEmptyTitle => 'Nenhum convite';

  @override
  String get invitationsEmptyMessage =>
      'Quando alguém convidar você para um círculo, aparecerá aqui.';

  @override
  String get refreshRingSemanticNoInbox =>
      'Nenhuma caixa de entrada configurada, abre as configurações de relays';

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
      other: '$checkedString de $totalString relays verificados',
      many: '$checkedString de $totalString relays verificados',
      one: '$checkedString de 1 relay verificado',
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
      other: 'Todos os $totalString relays responderam',
      many: 'Todos os $totalString relays responderam',
      one: 'O relay respondeu',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'Nenhum relay respondeu';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relays responderam';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Verificando relays';

  @override
  String get refreshRingAnnouncementAllOk => 'Todos os relays responderam';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relays responderam';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'Não foi possível alcançar nenhum relay';

  @override
  String get refreshRingAnnouncementNoInbox =>
      'Nenhuma caixa de entrada configurada';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'Todos os $totalString relays têm os seus dados',
      many: 'Todos os $totalString relays têm os seus dados',
      one: 'O relay tem os seus dados',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'Nenhum relay tem os seus dados';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relays têm os seus dados';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'Todos os relays têm os seus dados';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString de $totalString relays têm os seus dados';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'Nenhum relay tem os seus dados';

  @override
  String get identityTitle => 'Identidade';

  @override
  String get identityLoadError =>
      'Algo deu errado ao carregar sua identidade. Tente de novo.';

  @override
  String get identityMissingTitle => 'Sem identidade';

  @override
  String get identityMissingMessage =>
      'Sua identidade desapareceu. Configure uma nova para continuar usando o Haven.';

  @override
  String get identitySetUpCta => 'Configurar identidade';

  @override
  String get identityPublicKeyQrTitle => 'QR da chave pública';

  @override
  String get identityPublicKeyQrSubtitle =>
      'Como os outros convidam você para círculos';

  @override
  String get identityAdvancedTitle => 'Avançado';

  @override
  String get identityAdvancedSubtitle =>
      'Chave pública, chave secreta, excluir';

  @override
  String get identityVisibilityNote =>
      'Apenas os membros dos círculos dos quais você participa podem ver sua foto e seu nome de exibição. Os convites são enviados usando chaves públicas ou QR codes.';

  @override
  String get identityAdvancedExportError =>
      'Falha ao exportar a chave secreta. Tente de novo.';

  @override
  String get identityAdvancedDeleteTitle => 'Excluir identidade?';

  @override
  String get identityAdvancedDeleteBody =>
      'Isso excluirá sua identidade permanentemente. Certifique-se de ter feito o backup da sua chave secreta caso queira recuperá-la.';

  @override
  String get identityAdvancedDeleteConfirm => 'Excluir';

  @override
  String get identityAdvancedDeletedSnack => 'Identidade excluída';

  @override
  String get identityAdvancedDeleteError =>
      'Falha ao excluir a identidade. Tente de novo.';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label copiada para a área de transferência';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Chave secreta copiada. Aviso: outros apps podem ler sua área de transferência. Cole-a em um local seguro e limpe sua área de transferência.';

  @override
  String get identityAdvancedMissingBody => 'Nenhuma identidade configurada.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Chave pública';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'Chave pública (hex)';

  @override
  String get identityAdvancedCopyValue => 'Chave pública';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'Copiar chave pública';

  @override
  String get identityAdvancedCopyHexTooltip => 'Copiar hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'Chave secreta';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Sua chave secreta dá acesso total à sua identidade. Nunca a compartilhe com ninguém.';

  @override
  String get identityAdvancedRevealSecretKey => 'Revelar chave secreta';

  @override
  String get identityAdvancedHideSecretKey => 'Ocultar chave secreta';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'Copiar chave secreta';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Excluir identidade';

  @override
  String get qrCodeLoadError =>
      'Algo deu errado ao carregar sua chave pública. Tente de novo.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Sua chave pública';

  @override
  String get qrCodeWhatIsThisTitle => 'O que é isso?';

  @override
  String get qrCodeExplainerKeys =>
      'O Haven funciona com base no Nostr, uma rede aberta sem nenhuma conta de empresa ou cadastro por trás. Sua identidade é apenas um par de chaves: uma chave secreta que só você guarda e esta chave pública gerada a partir dela.';

  @override
  String get qrCodeExplainerUsername =>
      'Sua chave pública funciona como um nome de usuário que é seguro compartilhar. As pessoas escaneiam este código, ou colam sua chave pública, para convidar você para um círculo. Ela não pode revelar seu nome de exibição, sua foto nem sua localização, que só são compartilhados com os membros dos círculos dos quais você participa.';

  @override
  String get displayNameCardTitle => 'Nome de exibição';

  @override
  String get displayNameCardLoadError =>
      'Não foi possível carregar seu nome de exibição. Tente mais tarde.';

  @override
  String get displayNameCardHint => 'Digite seu nome de exibição';

  @override
  String get displayNameCardSavedLabel => 'Nome de exibição salvo';

  @override
  String get displayNameCardSaveLabel => 'Salvar nome de exibição';

  @override
  String get displayNameCardSavingLabel => 'Salvando o nome de exibição';

  @override
  String get displayNameCardRetryLabel => 'Falha ao salvar. Tente de novo';

  @override
  String get displayNameCardSavedAnnouncement => 'Nome de exibição salvo';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'Falha ao salvar, tente de novo';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$label copiada para a área de transferência';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'revelada';

  @override
  String get keyDisplayStateHidden => 'oculta';

  @override
  String get keyDisplayHideTooltip => 'Ocultar';

  @override
  String get keyDisplayRevealTooltip => 'Revelar';

  @override
  String get keyDisplayCopyTooltip => 'Copiar';

  @override
  String get keyDisplayCompactCopied =>
      'Chave copiada para a área de transferência';

  @override
  String get keyDisplayCompactTapToCopy => 'Toque para copiar';

  @override
  String get npubQrCopiedSnack =>
      'Chave pública copiada para a área de transferência';

  @override
  String get npubQrCopyButton => 'Copiar chave pública';

  @override
  String get circleMemberPublicKeyCopied =>
      'Chave pública copiada para a área de transferência';

  @override
  String get circleMemberCopyPublicKeyHint => 'Copiar chave pública';

  @override
  String get npubQrScanLabel => 'Escaneie para me adicionar';

  @override
  String get npubQrSemanticsLabel => 'QR code da sua identidade pública';

  @override
  String get photoHeaderRemoveTitle => 'Remover a foto de perfil?';

  @override
  String get photoHeaderRemoveBody =>
      'Isso remove sua foto para todos nos seus círculos.';

  @override
  String get photoHeaderEditPhoto => 'Editar foto';

  @override
  String get photoHeaderRemove => 'Remover';

  @override
  String get photoHeaderViewPhotoSemantics => 'Ver foto de perfil';

  @override
  String get photoHeaderAddPhotoSemantics => 'Adicionar foto de perfil';

  @override
  String get photoHeaderChangePhotoSemantics => 'Alterar foto de perfil';

  @override
  String get avatarPickerPhotoUpdated =>
      'Foto atualizada — compartilhada com seus círculos, criptografada de ponta a ponta.';

  @override
  String get avatarPickerPhotoRemoved => 'Foto removida.';

  @override
  String get avatarPickerRemoveError =>
      'Não foi possível remover sua foto. Tente de novo.';

  @override
  String get avatarPickerUpdateError =>
      'Não foi possível atualizar sua foto. Tente de novo.';

  @override
  String get avatarPickerCropTitle => 'Cortar foto';

  @override
  String get avatarPickerCropDone => 'Concluir';

  @override
  String get avatarPickerCropCancel => 'Cancelar';

  @override
  String get avatarFullscreenClose => 'Fechar';

  @override
  String get avatarFullscreenSemantics => 'Foto de perfil, tela cheia';

  @override
  String get avatarFullscreenLoadError => 'Não foi possível carregar a foto';

  @override
  String get mapInitializing => 'Inicializando...';

  @override
  String get mapInitFailedTitle => 'Falha na inicialização';

  @override
  String get mapInitFailedMessage =>
      'Falha ao inicializar os serviços de localização.';

  @override
  String get mapInitFailedRetry => 'Falha na inicialização. Tente de novo.';

  @override
  String get mapLocationOffMessage =>
      'Ative a localização para ver você e seus círculos no mapa.';

  @override
  String get mapGettingLocation => 'Obtendo a localização...';

  @override
  String get mapLoadingMap => 'Carregando o mapa...';

  @override
  String get mapLocationOffTitle => 'A localização está desativada';

  @override
  String get mapLocationErrorTitle => 'Erro de localização';

  @override
  String get mapLocationUnavailable =>
      'Localização temporariamente indisponível';

  @override
  String get mapThisLocation => 'este local';

  @override
  String get mapMemberFallbackName => 'membro';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return 'Abrir $label no Apple Maps?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Apenas a coordenada do mapa é enviada ao Apple Maps, nunca um nome ou identidade.';

  @override
  String get mapOpenInAppleMapsConfirm => 'Abrir no Apple Maps';

  @override
  String get mapOpenMapsError => 'Não foi possível abrir o Maps';

  @override
  String get mapControlsZoomIn => 'Aproximar';

  @override
  String get mapControlsZoomOut => 'Afastar';

  @override
  String get mapControlsRecenter => 'Recentralizar';

  @override
  String get mapControlsRecenterFab => 'Recentralizar na minha localização';

  @override
  String get mapAttributionCreditsButton => 'Créditos e licença do mapa';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'Marcador da sua localização$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Precisão: $metersString metros';
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
      other: 'há $countString minutos',
      many: 'há $countString de minutos',
      one: 'há 1 minuto',
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
      other: 'há $countString horas',
      many: 'há $countString de horas',
      one: 'há 1 hora',
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
      other: 'há $countString dias',
      many: 'há $countString de dias',
      one: 'há 1 dia',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'Marcador do membro $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'Marcador de membro';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, visto pela última vez $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name está fora da tela, a $direction; toque para ver';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'Um membro está fora da tela, a $direction; toque para ver';
  }

  @override
  String get compassNorth => 'norte';

  @override
  String get compassNorthEast => 'nordeste';

  @override
  String get compassEast => 'leste';

  @override
  String get compassSouthEast => 'sudeste';

  @override
  String get compassSouth => 'sul';

  @override
  String get compassSouthWest => 'sudoeste';

  @override
  String get compassWest => 'oeste';

  @override
  String get compassNorthWest => 'noroeste';

  @override
  String get commonAdd => 'Adicionar';

  @override
  String get addRelaySheetTitleInbox => 'Adicionar relay de caixa de entrada';

  @override
  String get addRelaySheetTitleKeyPackage => 'Adicionar relay de KeyPackage';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Colar da área de transferência';

  @override
  String get addRelaySheetErrorEmpty => 'Informe um endereço de relay.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Use wss:// para que o tráfego até este relay seja criptografado.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'A URL do relay não pode conter credenciais.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'Informe um endereço de relay como wss://relay.example.com.';

  @override
  String get avatarSemanticsLabel => 'Avatar do usuário';

  @override
  String avatarSemanticsFor(String initials) {
    return 'de $initials';
  }

  @override
  String get avatarSemanticsOnline => 'on-line';

  @override
  String get avatarSemanticsOffline => 'off-line';
}
