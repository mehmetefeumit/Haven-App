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
      'O Haven não tem servidor central. Suas mensagens criptografadas trafegam por servidores independentes chamados relays, e você escolhe quais usar. Nenhuma empresa ou governo sozinho consegue desligar a rede.';

  @override
  String get onboardingValueProp3Title => 'Não precisa de conta';

  @override
  String get onboardingValueProp3Body =>
      'Sem e-mail, sem telefone, sem cadastro. O Haven cria uma identidade cuja chave secreta nunca sai do seu celular, então não existe nenhuma conta que alguém possa entregar.';

  @override
  String get onboardingValueProp1Summary =>
      'Criptografada no seu dispositivo, então só os círculos que você escolher podem lê-la.';

  @override
  String get onboardingValueProp2Summary =>
      'Sem servidor central. Funciona em uma rede de relays que você escolhe.';

  @override
  String get onboardingValueProp3Summary =>
      'Sem e-mail, telefone ou cadastro. Sua chave secreta nunca sai do seu celular.';

  @override
  String get onboardingCreateIdentityTitle => 'Crie sua identidade';

  @override
  String get onboardingCreateIdentityBody =>
      'O Haven cria suas chaves neste telefone. A secreta nunca sai dele.';

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
  String get onboardingDisplayNameHint => 'ex.: Alex';

  @override
  String get onboardingDisplayNameError =>
      'Não foi possível salvar esse nome. Tente de novo.';

  @override
  String get onboardingAddPhotoOptional => 'Adicionar uma foto (opcional)';

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
      'kind 10002, onde as pessoas encontram as chaves de que precisam para convidar você';

  @override
  String get relaySettingsProfileTitle => 'Meus relays de perfil';

  @override
  String get relaySettingsProfileSubtitle =>
      'kind 0, onde seu perfil público é consultado e publicado. Esses relays são mantidos separados dos seus demais relays, e a lista dos relays de perfil nunca é publicada';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'Consultas de perfil pausadas';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'Restaram poucos relays de perfil, então os nomes e as fotos dos membros deixarão de ser atualizados.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Restaurar relays de perfil padrão';

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
  String get relaySettingsProfileContaminationTooltip =>
      'Também transporta outro tráfego do Haven';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Aviso: $url também transporta o restante do seu tráfego do Haven, então esse relay pode associar seu perfil a esse tráfego';
  }

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
      'O Haven compartilha sua localização com seus círculos sempre que o app está aberto. Ative esta opção e seus círculos continuam vendo a localização enquanto o Haven está em segundo plano; se o sistema fechar o Haven, as atualizações voltam quando você se desloca ou quando o sistema acorda o app da próxima vez.';

  @override
  String get locationSettingsToggleTitle => 'Compartilhar em segundo plano';

  @override
  String get locationSettingsToggleSubtitle =>
      'Continuar compartilhando com o app fechado';

  @override
  String get locationSettingsIosLimitedNote =>
      'O compartilhamento continua funcionando em segundo plano com sua permissão atual. Escolha \"Sempre\" para o Haven nos Ajustes para que as atualizações também possam ser retomadas depois que o iOS fechar o app.';

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
      'Enquanto o compartilhamento em segundo plano está ativado, o Haven mantém uma sessão de localização contínua e o iOS mostra um indicador azul na barra de status. Conceder \"Sempre\" também permite que o Haven recupere as atualizações dos seus círculos depois que o iOS fechar o app.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Licenciado sob a MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Versão $version';
  }

  @override
  String get privacyTitle => 'Privacidade';

  @override
  String get privacySubtitle =>
      'Como o Haven funciona e o que os outros podem ver';

  @override
  String get privacyHubSummary =>
      'O Haven compartilha sua localização apenas com os pequenos grupos que você escolhe, chamados círculos, e a criptografa no seu telefone antes de ela sair. Não há cadastro nem servidor do Haven. A única coisa pública é o nome de exibição e a foto que você define. As páginas abaixo explicam isso, e todo o resto, em linguagem simples.';

  @override
  String get privacyGroupBasicsHeading => 'O básico';

  @override
  String get privacyMeansForYouLabel => 'O que isso significa para você';

  @override
  String get privacyMoreDetailLabel => 'Em mais detalhes';

  @override
  String get privacyMoreDetailExpandHint => 'Mostrar os detalhes técnicos';

  @override
  String get privacyMoreDetailCollapseHint => 'Ocultar os detalhes técnicos';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'Detalhes técnicos exibidos';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Detalhes técnicos ocultos';

  @override
  String get privacyWhatHavenIsTitle =>
      'O que é o Haven e por que não existe conta';

  @override
  String get privacyWhatHavenIsSubtitle =>
      'Sem cadastro, sem servidor de empresa';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'O Haven compartilha sua localização com pequenos grupos que você escolhe, chamados círculos. Não existe conta por trás disso. Você nunca informa e-mail, telefone nem senha.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'O Haven também não opera servidores próprios. Suas atualizações de localização criptografadas passam por servidores independentes chamados relays, mantidos por outras pessoas. Os desenvolvedores do Haven não conseguem ver sua localização e não colocaram nenhum rastreamento no app. A única coisa que eles veem é o total de uso do mapa: os blocos do mapa são baixados com uma única chave compartilhada, nunca quem os baixou.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'Ninguém pode ser obrigado a entregar seus dados, porque ninguém os guarda. O custo é que também não há quem restaure sua identidade para você. Veja “Suas duas chaves” para saber do que fazer backup.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'O app não contém código de análise, de relatório de falhas nem de publicidade. Como o Haven é de código aberto, isso pode ser verificado, e não apenas aceito com base na confiança.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'O Haven também não tem notificações push, de propósito. Um serviço de notificações precisaria ser avisado sempre que alguém dos seus círculos tivesse algo a entregar, o que revelaria mais sobre seus hábitos do que os relays revelam.';

  @override
  String get privacyYourKeysTitle =>
      'Suas duas chaves: uma secreta, outra para compartilhar';

  @override
  String get privacyYourKeysSubtitle =>
      'O que identifica você e do que fazer backup';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'Em vez de nome de usuário e senha, você tem um par de chaves. A chave secreta prova que você é você. A chave pública é o que os outros usam para encontrar e convidar você.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Sua chave secreta fica guardada só neste telefone, em um armazenamento protegido pelo sistema operacional. O Haven nunca a envia para lugar nenhum: nem para servidor algum, nem para nós.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Sua chave pública pode ser entregue sem risco. Ela funciona como um nome de usuário que você pode publicar em qualquer lugar. Compartilhá-la não revela onde você está.';

  @override
  String get privacyYourKeysMeansForYou =>
      'Para manter esta identidade, faça um backup dela. Vá em Configurações → Identidade → Avançado, toque em Revelar chave secreta e guarde-a em um lugar seguro, como um gerenciador de senhas. Sem esse backup, perder o telefone significa perder a identidade para sempre.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Qualquer pessoa que obtenha sua chave secreta passa a ser você. Poderia entrar em círculos no seu lugar ou publicar em seu nome. Nunca cole essa chave em outro app, em uma mensagem ou em um site.';

  @override
  String get privacyYourKeysDetailFormats =>
      'As duas chaves são secp256k1, exibidas nos formatos padrão do Nostr: npub1… para a chave pública e nsec1… para a secreta. A assinatura acontece dentro do app, e a chave secreta é limpa das partes que lidam diretamente com ela assim que é usada.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'As chaves que criptografam as mensagens dos seus círculos são separadas desta chave de identidade e ficam apenas com o app. Essa separação é intencional: a chave que diz quem você é não é a chave que abre o que você enviou.';

  @override
  String get privacyPublicProfileTitle => 'Seu nome e sua foto são públicos';

  @override
  String get privacyPublicProfileSubtitle =>
      'Visíveis para qualquer pessoa, não só para seus círculos';

  @override
  String get privacyPublicProfileIsPublic =>
      'O nome de exibição e a foto que você definir são publicados no Nostr, a rede pública e aberta em que o Haven funciona. Qualquer pessoa pode consultá-los, não apenas quem está nos seus círculos.';

  @override
  String get privacyPublicProfileOnSave =>
      'Seu nome e sua foto se tornam públicos no momento em que você os salva. Não existe configuração que os mantenha privados, nem forma de compartilhar um nome só com seus círculos.';

  @override
  String get privacyPublicProfilePseudonym =>
      'Novas instalações começam com um nome inventado, como “Quiet Wanderer”, que não diz nada sobre você. Você pode mantê-lo ou trocá-lo pelo que quiser.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Escolha um nome e uma foto que você não se incomode de mostrar em público. Se preferir que não te reconheçam, mantenha o nome inventado que você recebeu e não coloque foto.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Remover sua foto depois não apaga a cópia que está no servidor. O Haven substitui seu perfil por um perfil vazio. O arquivo da imagem continua onde está hospedado, e qualquer cópia já baixada continua por aí. Trate tudo o que você publica como permanente.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'O perfil é um evento Nostr “kind 0” assinado pela sua chave de identidade. As fotos são enviadas para um host público de imagens, o blossom.primal.net, que vê a imagem, sua chave pública e seu endereço de rede. O Haven ainda não permite que você escolha outro host.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Antes de enviar, o Haven recodifica a imagem e descarta os dados ocultos que as câmeras anexam, incluindo a posição GPS onde a foto foi tirada. Isso importa aqui: caso contrário, uma foto de viagem pode carregar as coordenadas da sua casa.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'O caminho da sua localização';

  @override
  String get privacyRelaysTitle =>
      'Relays: os servidores que repassam as mensagens';

  @override
  String get privacyRelaysSubtitle =>
      'Por quais computadores suas atualizações passam';

  @override
  String get privacyRelaysWhatIsARelay =>
      'O Haven não tem servidor próprio, então suas atualizações passam pelos servidores de outras pessoas. Eles são chamados de relays: servidores pequenos e independentes que qualquer pessoa pode operar. Um relay guarda a mensagem criptografada por pouco tempo e a repassa quando seu círculo a solicita.';

  @override
  String get privacyRelaysWhyMany =>
      'O Haven usa vários relays, então nenhum deles sozinho pode deixar você sem comunicação. Se um sair do ar, os outros continuam funcionando. Você escolhe os relays por onde os convites chegam até você; os relays que um círculo usa são definidos quando ele é criado.';

  @override
  String get privacyRelaysYourLists =>
      'O Haven mantém três listas para você. Seus relays de caixa de entrada são por onde os convites chegam até você, e seus relays de KeyPackage são onde as pessoas buscam as chaves de que precisam para convidar você — o Haven publica essas duas listas para que os outros consigam encontrá-las. Seus relays de perfil são diferentes: é neles que seu nome e sua foto são consultados e publicados, mas a lista em si fica no seu dispositivo e nunca é publicada. Por isso, um relay que só transporta seu tráfego de localização ou seus convites não tem nenhuma lista pública que lhe diga quais relays você usa para o seu perfil. Cada círculo também tem a sua própria lista, e é por ela que passam as atualizações criptografadas daquele círculo.';

  @override
  String get privacyRelaysMeansForYou =>
      'Um relay nunca vê sua localização, porque ela é criptografada antes de sair do seu telefone. Ele vê o que precisa ser público para as pessoas alcançarem você: seu nome e sua foto, as chaves de que os outros precisam para convidar você e a sua própria lista de relays. O Haven já começa com relays funcionando, então não há nada que você precise mudar.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Além das suas próprias listas, o Haven consulta um pequeno conjunto de relays públicos de diretório para procurar perfis e chaves de outras pessoas. Ele entra em contato com esses relays mesmo que você tenha configurado apenas relays privados seus. Eles veem seu endereço de rede e sobre quais contas você perguntou.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'Sua lista de relays de KeyPackage é assinada pela sua chave de identidade e publicada nos relays que já estão nela. Se você adicionar um relay privado ali, o endereço dele se torna público e ligado a você. Não há como manter privado um relay que esteja nessa lista.';

  @override
  String get privacyEncryptionTitle => 'Como funciona a criptografia';

  @override
  String get privacyEncryptionSubtitle =>
      'Uma chave por círculo e o que muda quando alguém entra ou sai';

  @override
  String get privacyEncryptionPerCircle =>
      'Sua localização é criptografada no seu telefone antes de sair, com um padrão aberto chamado MLS. Cada círculo é seu próprio grupo criptografado, com suas próprias chaves. Ninguém de fora de um círculo consegue ler o que é enviado dentro dele: nem um relay, nem o Haven, nem outro círculo do qual você participa.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'Quando alguém entra, o círculo passa a usar uma chave nova. Essa pessoa pode ler o que for enviado depois da chegada dela, e nada do que veio antes. O Haven nunca envia localizações antigas a um novo membro.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'Quando alguém sai de um círculo, ele passa a usar outra chave nova. Essa pessoa deixa de conseguir ler qualquer coisa nova assim que o restante do círculo se atualiza, normalmente em alguns minutos, e mais tempo para quem estava off-line na hora.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Sair de um círculo não recupera o que os membros dele já salvaram. O Haven troca as chaves apenas quando alguém entra ou sai, nunca por tempo decorrido. Por isso uma única chave pode cobrir semanas de mensagens, e tudo o que um membro salvou nesse período continua legível para ele. Ainda assim, ele não consegue abrir nada enviado depois que saiu.';

  @override
  String get privacyEncryptionMeansForYou =>
      'A criptografia protege você de todos que estão fora dos seus círculos. Ela não protege você de quem já esteve dentro de um deles. Para parar de compartilhar com uma pessoa específica, saia do círculo que você compartilha com ela e crie um novo sem ela.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) é o mesmo padrão do IETF usado por outros mensageiros seguros. O Haven chega à rede Nostr pelo protocolo Marmot, que define como os grupos MLS viajam pelos relays. A chave com que cada círculo assina é separada da sua chave pública de identidade do Nostr.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Cada período de chave é chamado de epoch, e um círculo só passa para um novo quando a composição dele muda. Seu aparelho guarda as chaves do epoch atual e de alguns recentes, o suficiente para abrir as mensagens que ainda estão chegando, e descarta o resto. Um círculo cuja composição não muda há meses ainda está no epoch em que começou.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'O que os membros veem e o que os relays veem';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'As pessoas com quem você compartilha e os servidores no meio do caminho';

  @override
  String get privacyWhatOthersSeeMembersHeading =>
      'As pessoas dos seus círculos';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Todos em um círculo veem sua posição exata no mapa, não uma área aproximada. Não existe configuração que compartilhe uma localização vaga com alguns membros e uma precisa com outros.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Enquanto o Haven está aberto e você participa de um círculo, sua posição sai sozinha a cada poucos minutos. Não há botão de pausa: a opção na página Localização controla apenas se isso continua depois que você fecha o app. Para parar de compartilhar com um círculo, abra-o e escolha Sair do círculo.';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Entrar em um círculo também mostra sua chave pública a todos os membros. Por meio dela, eles podem consultar seu perfil público e tudo o mais que você já publicou com essa chave.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Seu telefone baixa a foto de perfil de cada membro de um servidor escolhido por esse membro, sem que você toque em nada. Esse servidor passa então a ver seu endereço de rede, o que coloca você aproximadamente no mapa. Uma VPN oculta isso; nada mais oculta.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'Os operadores dos relays';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Os relays, os servidores independentes por onde suas atualizações passam, não conseguem ler sua localização, suas mensagens, o nome do seu círculo nem a lista de membros dele. Suas atualizações de localização levam um endereço de envio novo e de uso único, em vez da sua chave pública. Já o seu perfil, os convites e as listas de relays levam a chave pública, então um relay que cuida dos dois muitas vezes consegue perceber que você está em um círculo, sem ler nada do que há dentro.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'O que eles veem é seu endereço de rede, quando você está online e o tamanho e a frequência do seu tráfego. Cada círculo carrega uma etiqueta aleatória. Um relay consegue agrupar as mensagens de um círculo por essa etiqueta e estimar quantas pessoas há nele, sem descobrir quem são.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Só entre em um círculo com pessoas a quem você daria o endereço da sua casa. A criptografia se mantém contra relays e gente de fora, e uma VPN oculta o endereço de onde seu telefone se conecta. Nada protege você de um membro que tira uma captura de tela.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'A etiqueta de um círculo permanece a mesma por toda a vida dele, então um relay pode ligar todas as mensagens dele entre si por tempo indeterminado. Isso é uma característica do protocolo subjacente, não algo que o Haven possa mudar.';

  @override
  String get commonLearnMore => 'Saiba mais';

  @override
  String get relaySettingsBackendCaption =>
      'O Haven não tem servidor próprio. Suas atualizações criptografadas passam por servidores independentes chamados relays, que não conseguem ler sua localização nem suas mensagens.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'Isso depende do seu telefone. No Android, o Haven bloqueia capturas de tela e gravação de tela em todo o app. No iPhone, ele não consegue: o Haven desfoca a pré-visualização no alternador de apps, mas um membro ainda pode capturar o que está na tela.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'O Haven pede aos relays que descartem as mensagens de localização depois de cerca de quatro minutos. Esse pedido é apenas uma recomendação: o relay tem liberdade para guardá-las por mais tempo. Os convites não têm prazo nenhum e podem ficar no seu relay de caixa de entrada por tempo indeterminado.';

  @override
  String get privacyGroupTheLimitsHeading => 'Os limites';

  @override
  String get privacyInferenceTitle => 'O que ainda dá para deduzir sobre você';

  @override
  String get privacyInferenceSubtitle =>
      'Os rastros que a criptografia não oculta';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'A criptografia oculta o que você envia. Ela não consegue ocultar que você enviou algo. Esse rastro que sobra tem um nome: metadados. São a hora em que uma mensagem saiu, o tamanho dela e a quais servidores você estava conectado. Isso continua visível mesmo quando o conteúdo não está.';

  @override
  String get privacyInferenceActivityPattern =>
      'A partir desses metadados, um relay que você usa consegue perceber mais ou menos quando você está ativo e com que frequência. O Haven também envia uma atualização extra sempre que você se desloca cerca de cem metros. Ao longo de horas, isso pode mostrar a um relay se você estava em movimento ou parado. Nunca mostra onde.';

  @override
  String get privacyInferencePresence =>
      'Enquanto o Haven está em execução, ele mantém uma conexão aberta com seus relays. Eles conseguem ver que você está online e quais etiquetas de círculo você acompanha, nunca o nome de um círculo nem quem está nele. Esse é o preço de as atualizações chegarem em segundos, e não em minutos.';

  @override
  String get privacyInferenceIpHeading => 'Seu endereço de rede';

  @override
  String get privacyInferenceIpAddress =>
      'Todo servidor com que o Haven fala vê o endereço de onde seu telefone se conecta, o endereço IP dele: seus relays, o provedor do mapa e quem hospeda a foto de perfil de um membro. Seu provedor de internet vê quais desses servidores você acessou, e quando. O Haven, por si só, não faz nada para ocultar nenhuma das duas coisas.';

  @override
  String get privacyInferenceMapTilesHeading => 'O mapa em si';

  @override
  String get privacyInferenceMapTiles =>
      'Para desenhar o mapa, o Haven pede ao provedor do mapa os quadrados de imagem que estão na tela, então ele fica sabendo mais ou menos quais lugares você olha. O Haven também baixa com antecedência uma pequena área em volta de cada membro que você consegue ver, para o mapa já estar pronto quando você chegar lá: ou seja, o provedor consegue saber mais ou menos onde o seu círculo está, e não apenas para onde você está olhando. Esses quadrados ficam em um cache criptografado no seu telefone por até sete dias e são apagados caso você exclua sua identidade.';

  @override
  String get privacyInferenceVpnHeading => 'Vale a pena usar uma VPN?';

  @override
  String get privacyInferenceVpnHelps =>
      'Uma VPN substitui seu endereço pelo dela, então os relays e os outros servidores não veem mais de onde você se conecta. Ela também oculta do seu provedor de internet quais servidores você acessa. Recomendamos a Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'Ela não resolve tudo. Uma VPN não muda nada do que os membros do seu círculo veem. E, para o relay com o qual você está conversando, ela não oculta o momento nem o tamanho do seu tráfego. Ela também apenas transfere sua confiança para o provedor da VPN, em vez de eliminar a necessidade de confiar em alguém.';

  @override
  String get privacyInferenceMeansForYou =>
      'Preocupado com os relays, com seu provedor de internet ou com os servidores de mapa colocando você no mapa? Uma VPN é a coisa mais útil que você pode acrescentar. Preocupado com as pessoas dos seus círculos? Ela não vai ajudar em nada.';

  @override
  String get privacyInferenceDetailJitter =>
      'O Haven varia de propósito o intervalo entre as atualizações, então uma gravação curta não mostra nenhum ritmo claro. Na média de muitas horas, a frequência real ainda pode ser estimada. As mensagens também não recebem preenchimento para igualar o tamanho, e as atualizações de localização ficam em uma faixa estreita de tamanho, o que as torna reconhecíveis como atualizações de localização.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Duas coisas estão além de qualquer decisão de design aqui: alguém capaz de observar muitos relays ao mesmo tempo e seu próprio telefone depois que outra pessoa passa a controlá-lo.';

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
  String get createCircleNoAccountFound =>
      'Não foi encontrada uma conta do Haven para este ID';

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
      'Todos neste círculo podem ver a localização, o nome público e a foto uns dos outros. Seu nome e sua foto são públicos na rede Nostr, e não privados deste círculo. Este círculo permanece separado de quaisquer outros dos quais você participa, então seus membros não podem ver seus outros círculos nem quem está neles.';

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
      'Assim que a pessoa aceitar, ela verá a localização de todos a partir daquele momento, e nunca nada que tenha sido enviado antes de ela entrar. Ela também verá as chaves públicas de todos que já estão neste círculo.';

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
  String get pendingMemberRemoveTooltip => 'Remover da lista';

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
  String get pendingMemberNeedsUpdate => 'Precisa atualizar o Haven';

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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · epoch $epochString';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relays deste círculo';

  @override
  String get circleDetailsNoRelays => '(nenhum registrado)';

  @override
  String get circleDetailsRelaysNote =>
      'Esses relays foram copiados dos seus relays de caixa de entrada quando este círculo foi criado, e ainda não podem ser alterados. Mudanças posteriores na sua lista pessoal de relays não os alteram.';

  @override
  String get circleDetailsAddMember => 'Adicionar membro';

  @override
  String get circleDetailsLeaveCircle => 'Sair do círculo';

  @override
  String get leaveCircleDialogTitle => 'Sair do círculo';

  @override
  String get leaveCircleDialogBody =>
      'Sair deste círculo? Você deixará de enviar sua localização aos membros dele e de ver a localização deles. A última posição que você enviou fica nos telefones deles por até um dia. Isso não pode ser desfeito: você precisaria de um novo convite para voltar.';

  @override
  String get leaveCircleConfirm => 'Sair';

  @override
  String get leaveCircleIdentityUnavailable => 'Identidade indisponível';

  @override
  String get leaveCircleSuccess => 'Você saiu do círculo';

  @override
  String get leaveCircleError => 'Falha ao sair do círculo';

  @override
  String get circleBlockedBannerTitle => 'Este círculo não pode ser atualizado';

  @override
  String get circleBlockedBannerBody =>
      'Algo deu errado com a criptografia deste círculo, então o Haven não consegue mais enviar nem receber atualizações nele. Você ainda pode ver abaixo as últimas informações que tinha, ou sair do círculo.';

  @override
  String get legacyCircleBannerTitle => 'Este círculo precisa ser recriado';

  @override
  String get legacyCircleBannerBody =>
      'O mecanismo de criptografia do Haven foi atualizado, então este círculo não pode mais ser usado. Recrie-o para continuar compartilhando localização com as mesmas pessoas. Você precisará convidá-las novamente.';

  @override
  String get legacyCircleRecreateCta => 'Recriar círculo';

  @override
  String get legacyCircleRemoveCta => 'Remover';

  @override
  String get legacyCircleRemoveDialogTitle => 'Remover círculo?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'Este círculo não pode mais ser usado e será removido da sua lista. Isso não afeta nenhum novo círculo que você criar para substituí-lo.';

  @override
  String get legacyCircleRemoveConfirm => 'Remover';

  @override
  String get legacyCutoverExplainerTitle => 'O Haven foi atualizado';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Sua identidade e seu perfil público não mudaram. Não há nada que você precise fazer quanto a eles.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Para maior segurança, seus círculos precisam ser recriados e seus membros convidados novamente antes que você possa voltar a compartilhar localização neles.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Entendi';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'O Haven ainda está pedindo aos relays que descartem alguns dados antigos da atualização de segurança recente.';

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
  String get profileIsPublicNoticeTitle => 'Seu perfil é público';

  @override
  String get profileIsPublicNoticeBody =>
      'Seu nome de exibição e sua foto ficam visíveis para qualquer pessoa na rede Nostr, não apenas para os membros dos seus círculos. Compartilhe apenas o que você se sentir à vontade para tornar público.';

  @override
  String get identityRefreshProfileTooltip => 'Atualizar perfil público';

  @override
  String get identityAdvancedExportError =>
      'Falha ao exportar a chave secreta. Tente de novo.';

  @override
  String get identityAdvancedDeleteTitle => 'Excluir identidade?';

  @override
  String get identityAdvancedDeleteBody =>
      'Isso exclui sua identidade e todos os dados dos círculos deste telefone. Tudo o que já foi publicado com ela, incluindo seu nome, sua foto e suas chaves, permanece nos relays que têm esse conteúdo. Certifique-se de ter feito o backup da sua chave secreta caso queira recuperá-la.';

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
      'Sua chave pública funciona como um nome de usuário que é seguro compartilhar. As pessoas escaneiam este código, ou colam sua chave pública, para convidar você para um círculo. Compartilhá-la não revela onde você está. Seu nome de exibição e sua foto já são públicos, então isso não acrescenta nada.';

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
  String get circleMemberSetNicknameMenuItem => 'Definir apelido';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'Copiar chave pública';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'Não foi possível atualizar os perfis. Tente de novo.';

  @override
  String get memberDetailSheetTitle => 'Detalhes do membro';

  @override
  String get memberNicknameSheetHint => 'Digite um apelido';

  @override
  String get memberNicknameSheetLabel => 'Apelido';

  @override
  String get memberNicknameSheetSave => 'Salvar apelido';

  @override
  String get memberNicknameSheetClear => 'Limpar apelido';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Apelido salvo';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Apelido removido';

  @override
  String get npubQrScanLabel => 'Escaneie para me adicionar';

  @override
  String get npubQrSemanticsLabel => 'QR code da sua identidade pública';

  @override
  String get photoHeaderRemoveTitle => 'Remover a foto de perfil?';

  @override
  String get photoHeaderRemoveBody =>
      'Isso tira sua foto do seu perfil público. O arquivo da imagem continua no servidor que o hospeda, e as cópias que outras pessoas já baixaram continuam com elas.';

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
      'Foto atualizada. Publicada no seu perfil público do Nostr.';

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
  String get mapLocationNoPermissionTitle =>
      'O Haven não pode usar sua localização';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'A localização está desativada neste dispositivo, então o Haven parou de compartilhar sua posição com seus círculos. Ative a localização para voltar a compartilhar.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'O Haven não tem mais permissão para usar sua localização, então o compartilhamento parou. Permita o acesso à localização para voltar a compartilhar.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'Nas configurações do sistema, o acesso do Haven à localização está desativado, então o compartilhamento parou. Permita o acesso por lá para voltar a compartilhar.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'O Haven parou de compartilhar sua posição. Ative a localização deste dispositivo e permita que o Haven a acesse.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'O Haven parou de receber sua posição, então o compartilhamento foi interrompido. Verifique se a localização está ativada e se o Haven tem permissão para usá-la.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'O acesso à localização voltou. O Haven está compartilhando sua posição de novo.';

  @override
  String get clockSkewTitle => 'O relógio deste telefone está errado';

  @override
  String get clockSkewBodyRejected =>
      'Seus círculos não estão recebendo sua posição, porque os relays rejeitam o horário que este telefone marca nela. Ative a data e hora automáticas nas configurações do sistema para corrigir isso.';

  @override
  String get clockSkewBodyBehind =>
      'Este telefone está atrasado em relação ao resto dos seus círculos, então as posições que ele envia expiram antes que alguém consiga vê-las. Ative a data e hora automáticas nas configurações do sistema para corrigir isso.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'O relógio deste telefone já está certo. O Haven está compartilhando sua posição de novo.';

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
  String get addRelaySheetTitleProfile => 'Adicionar relay de perfil';

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
