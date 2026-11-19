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
      'Compartilhamento de localização privado e resistente à censura.';

  @override
  String get onboardingWelcomeCta => 'Começar';

  @override
  String get onboardingValueProp1Title => 'Só os seus círculos podem ver você';

  @override
  String get onboardingValueProp2Title => 'Ninguém pode desligá-lo';

  @override
  String get onboardingValueProp3Title => 'Não precisa de conta';

  @override
  String get onboardingValueProp1Summary =>
      'Criptografada no seu dispositivo, então só os círculos que você escolher podem lê-la. Nem os relays que a transportam conseguem.';

  @override
  String get onboardingValueProp2Summary =>
      'Sem servidor central. Funciona em relays independentes. Muita gente os mantém, então nenhuma empresa sozinha pode desligá-lo.';

  @override
  String get onboardingValueProp3Summary =>
      'Sem e-mail, telefone ou cadastro. Sua chave secreta nunca sai do seu celular. Fique com o nome anônimo que o Haven escolher ou crie o seu.';

  @override
  String get onboardingCreateIdentityTitle => 'Crie sua identidade';

  @override
  String get onboardingCreateIdentityCta => 'Criar minha identidade';

  @override
  String get onboardingCreateIdentityLoading => 'Preparando tudo…';

  @override
  String get onboardingFinishingSetup => 'Concluindo a configuração…';

  @override
  String get onboardingFinishSetupError =>
      'Não foi possível concluir a configuração da sua conta. Verifique sua conexão e tente de novo.';

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
  String get settingsRelaysTitle => 'Relays';

  @override
  String get settingsLocationTitle => 'Localização';

  @override
  String get settingsLocationSubtitleOn =>
      'Compartilhamento em segundo plano ativado';

  @override
  String get settingsLocationSubtitleOff =>
      'Somente enquanto o Haven está aberto';

  @override
  String get settingsMapStyleTitle => 'Estilo do mapa';

  @override
  String get settingsAboutTitle => 'Sobre';

  @override
  String get settingsDebugOverlayTitle => 'Sobreposição de log de depuração';

  @override
  String get settingsDebugOverlaySubtitle => 'Mostrar a saída de log na tela';

  @override
  String get relaySettingsTitle => 'Relays';

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
  String get relaySettingsKeyPackageTitle => 'Meus relays de KeyPackage';

  @override
  String get relaySettingsProfileTitle => 'Meus relays de perfil';

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
  String get relaySettingsStatusChecking => 'Verificando';

  @override
  String relaySettingsKindLine(String kind, String status) {
    return '$kind: $status';
  }

  @override
  String get relaySettingsKindKeyPackage => 'KeyPackage';

  @override
  String get relaySettingsKindRelayList => 'Lista de relays';

  @override
  String get relaySettingsKindInboxList => 'Lista de caixa de entrada';

  @override
  String get relaySettingsPresencePublished => 'Disponível';

  @override
  String get relaySettingsPresenceMissing => 'Ausente';

  @override
  String get relaySettingsPresenceOutdated => 'Versão antiga';

  @override
  String get relaySettingsLookupTitle => 'Relays de consulta';

  @override
  String get relaySettingsPublishingHeld =>
      'O Haven não vai publicar suas configurações de relays nem sua chave de convite até você continuar após o aviso sobre as configurações de relays';

  @override
  String get relaySettingsStatusNotChecked => 'Não verificado';

  @override
  String get relaySettingsPresencePublishing => 'Publicando…';

  @override
  String get relaySettingsPresenceRefused => 'O relay recusou';

  @override
  String get relaySettingsPresenceUnconfirmed => 'O relay não confirmou';

  @override
  String get relaySettingsPresenceNoAnswer => 'Não foi possível verificar';

  @override
  String get relaySettingsPresenceHeld => 'Em espera';

  @override
  String relaySettingsInfoTooltip(String section) {
    return 'Sobre a seção $section';
  }

  @override
  String get relaySettingsInboxInfoWhat =>
      'Quando alguém convida você para um círculo, o convite é entregue nesses relays. Relays são servidores independentes que repassam mensagens. O Haven verifica neles se há convites novos.';

  @override
  String get relaySettingsInboxInfoKeeps =>
      'O Haven guarda aqui sua lista de caixa de entrada. É uma nota pública curta que diz quais relays são sua caixa de entrada, para que as pessoas saibam para onde enviar convites. Uma cópia também vai para os relays de consulta, mais abaixo nesta página. Os convites são selados de modo que só você pode abri-los.';

  @override
  String get relaySettingsInboxInfoMissing =>
      'Quem usa o Haven procura sua lista de caixa de entrada nos relays de consulta, e outros apps podem procurá-la nos seus próprios relays, por isso o Haven mantém uma cópia nos dois. Cada linha mostra se aquele relay tem a versão atual.';

  @override
  String get relaySettingsInboxInfoActions =>
      'Você pode adicionar relays em que confia e remover os que não quer mais. O Haven não deixa você remover o último relay desta lista. Todos os relays desta lista são públicos: qualquer pessoa pode vê-los na sua lista de caixa de entrada. Quando você remove um relay, o Haven pede a ele que apague sua lista antiga.';

  @override
  String get relaySettingsInboxInfoTechnical =>
      'Para quem se interessa pelos detalhes técnicos: sua lista de caixa de entrada é um evento Nostr de kind 10050, e os convites chegam como eventos gift wrap de kind 1059.';

  @override
  String get relaySettingsKeyPackageInfoWhat =>
      'Para adicionar você a um círculo, quem convida precisa da sua chave de convite, chamada KeyPackage. O Haven a guarda nesses relays para que as pessoas possam convidar você mesmo quando seu telefone estiver desligado.';

  @override
  String get relaySettingsKeyPackageInfoKeeps =>
      'O Haven guarda duas coisas aqui: seu KeyPackage e sua lista de relays, uma nota pública curta que diz quais relays têm seu KeyPackage. Uma cópia da lista de relays também vai para os relays de consulta. Seu KeyPackage vai somente para os relays desta lista. Depois que ele é usado, o Haven o substitui por um novo e, de tempos em tempos, também o renova.';

  @override
  String get relaySettingsKeyPackageInfoMissing =>
      'Cada linha mostra se aquele relay tem seu KeyPackage e sua lista de relays atuais. Se um relay não tiver seu KeyPackage, ou tiver um antigo que o Haven já substituiu, quem procurar seu KeyPackage nesse relay talvez não consiga convidar você.';

  @override
  String get relaySettingsKeyPackageInfoActions =>
      'Você pode adicionar ou remover relays. O Haven não deixa você remover o último relay desta lista. Todos os relays desta lista são públicos: qualquer pessoa pode vê-los na sua lista de relays. Quando você remove um relay, o Haven pede a ele que apague sua lista de relays antiga.';

  @override
  String get relaySettingsKeyPackageInfoTechnical =>
      'Para quem se interessa pelos detalhes técnicos: o KeyPackage é um evento Marmot de kind 30443, e a lista de relays é um evento NIP-65 de kind 10002.';

  @override
  String get relaySettingsProfileInfoWhat =>
      'Quando você salva um nome ou uma foto, o Haven envia seu perfil público para esses relays. O Haven também consulta aqui os nomes e as fotos dos outros membros.';

  @override
  String get relaySettingsProfileInfoKeeps =>
      'Qualquer pessoa pode consultar seu perfil nesses relays. Sua foto em si fica guardada em um servidor de fotos separado, e seu perfil contém o endereço web dela.';

  @override
  String get relaySettingsProfileInfoPrivacy =>
      'O Haven envia seu perfil somente para esses relays, que ele mantém separados dos relays que transportam seus convites. Como seu perfil é público, outros apps podem copiá-lo para outros lugares. O Haven guarda esta lista no seu telefone e nunca a publica. Um relay desta lista que também transporta o restante do seu tráfego do Haven é marcado com um aviso.';

  @override
  String get relaySettingsProfileInfoActions =>
      'Você pode adicionar relays. Os relays de perfil embutidos no Haven não podem ser removidos, porque o Haven sempre os adiciona de volta. Esta seção não mostra símbolos ao lado dos relays; sua página Identidade mostra o perfil que você salvou.';

  @override
  String get relaySettingsProfileInfoTechnical =>
      'Para quem se interessa pelos detalhes técnicos: seu perfil é um evento Nostr de kind 0, e a foto fica guardada em um servidor Blossom.';

  @override
  String get relaySettingsLookupInfoWhat =>
      'Relays de consulta são relays públicos bem conhecidos onde os apps procuram os relays de alguém quando conhecem apenas a conta dessa pessoa. O Haven os escolheu, e eles são os mesmos para todos que usam o Haven. O Haven também os usa para encontrar as pessoas que você convida.';

  @override
  String get relaySettingsLookupInfoKeeps =>
      'Para que alguém que conhece apenas sua conta ainda possa convidar você, o Haven copia para cá sua lista de caixa de entrada e sua lista de relays, sem alterações. Se essas listas citarem um relay privado, esse nome também fica visível aqui. Nesse papel, o Haven copia para cá apenas essas duas listas. Alguns relays de consulta também são relays padrão do Haven para caixa de entrada e KeyPackage; enquanto estiverem nas suas listas, eles também guardam o que essas seções descrevem.';

  @override
  String get relaySettingsLookupInfoMissing =>
      'Cada linha mostra se aquele relay tem a versão atual das duas listas. Se um relay de consulta não tiver as listas ou tiver versões antigas, quem procurar ali talvez não encontre você. Um relay pode aparecer em mais de uma seção; cada seção mostra apenas o que aquela função precisa.';

  @override
  String get relaySettingsLookupInfoActions =>
      'Esta lista vem embutida no Haven, então não é possível alterá-la aqui. Você controla as listas de caixa de entrada e de KeyPackage acima.';

  @override
  String get relaySettingsLookupInfoTechnical =>
      'Para quem se interessa pelos detalhes técnicos: o Haven copia seus eventos de kind 10050 e kind 10002 para esses relays; o kind 30443 vai somente para seus relays de KeyPackage.';

  @override
  String get relaySettingsLegendTitle => 'O que os símbolos significam';

  @override
  String get relaySettingsLegendCurrent =>
      'Disponível: este relay tem a versão atual.';

  @override
  String get relaySettingsLegendPublishing =>
      'Publicando: o Haven já enviou e está aguardando a confirmação do relay.';

  @override
  String get relaySettingsLegendChecking =>
      'Verificando, ou ainda não verificado: o Haven está perguntando ao relay o que ele tem, ou ainda não perguntou.';

  @override
  String get relaySettingsLegendNotOnRelay =>
      'Ainda não está neste relay: está ausente, é uma versão antiga, o relay recusou ou o relay não confirmou. Toque em um símbolo para ver qual é o caso. O Haven tenta de novo na próxima verificação: aproximadamente a cada 10 minutos para seu KeyPackage e a cada 30 minutos para suas listas enquanto o Haven está aberto, e sempre que o Haven é iniciado. Se um dos seus relays continuar mostrando isto, você pode substituí-lo.';

  @override
  String get relaySettingsLegendNoAnswer =>
      'Não foi possível verificar: o relay não respondeu, talvez porque você esteja off-line ou ele esteja fora do ar. O Haven pergunta de novo na próxima verificação.';

  @override
  String get relaySettingsLegendHeld =>
      'Em espera: o Haven não está publicando isto por enquanto. Um aviso nesta página explica o motivo.';

  @override
  String get relaySettingsHeldNoRelays =>
      'O Haven não tem onde publicar uma lista acima que esteja sem relays. Toque em “Restaurar padrões” em cada lista vazia para voltar a publicá-la.';

  @override
  String get relaySettingsHeldNotYetPublished =>
      'O Haven ainda não publicou uma das suas listas de relays. Ele fará isso na próxima verificação.';

  @override
  String relaySettingsCheckSettled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Verificação dos relays concluída. $count relays não têm confirmação de que estão atualizados.',
      many:
          'Verificação dos relays concluída. $count de relays não têm confirmação de que estão atualizados.',
      one:
          'Verificação dos relays concluída. Um relay não tem confirmação de que está atualizado.',
      zero: 'Verificação dos relays concluída. Está tudo atualizado.',
    );
    return '$_temp0';
  }

  @override
  String relaySettingsAddedRelayUpToDate(String relay) {
    return '$relay está atualizado.';
  }

  @override
  String relaySettingsAddedRelayNotUpToDate(String relay) {
    return 'Não há confirmação de que $relay esteja atualizado. A linha dele explica por quê.';
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
  String get locationSettingsBatteryOptNote =>
      'A otimização de bateria continua ativada para o Haven. Alguns celulares a usam para interromper o compartilhamento em segundo plano sem avisar. Exclua o Haven da otimização para manter o compartilhamento confiável.';

  @override
  String get locationSettingsErrorSnack => 'Algo deu errado';

  @override
  String get locationSettingsIntro =>
      'O Haven compartilha sua localização com seus círculos sempre que o app está aberto. Ative esta opção e seus círculos continuam vendo a localização enquanto o Haven está em segundo plano. Se o sistema fechar o Haven, seu próprio compartilhamento é interrompido — o Haven ainda pode acordar para buscar a localização dos seus círculos, mas nunca para enviar a sua. No Android, o compartilhamento continua mesmo quando você desliza o Haven para fora da lista de apps recentes e volta a funcionar sozinho depois que o telefone é reiniciado. No iPhone, o compartilhamento continua interrompido até você abrir o Haven.';

  @override
  String get locationSettingsToggleTitle => 'Compartilhar em segundo plano';

  @override
  String get locationSettingsToggleSubtitle =>
      'Continuar compartilhando enquanto o Haven estiver em segundo plano';

  @override
  String get locationSettingsIosLimitedNote =>
      'O compartilhamento continua funcionando em segundo plano com sua permissão atual, e enquanto isso o iOS mostra a própria barra azul de localização no topo da tela. Escolha \"Sempre\" para o Haven nos Ajustes para que ele também possa recuperar as localizações dos seus círculos depois que o iOS fechar o app. Com \"Sempre\", o iOS pode mostrar a seta de localização na barra de status em vez dessa barra azul. Seu próprio compartilhamento é retomado quando você reabre o Haven.';

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
      'Enquanto o compartilhamento em segundo plano está ativado, o Haven mantém uma sessão de localização para que seus círculos continuem vendo você.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'O iOS mostra a própria seta de localização na barra de status enquanto o Haven usa sua localização e, depois disso, mantém essa mesma seta ao lado do Haven em Serviços de Localização por um tempo.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'Com sua permissão \"Sempre\", o iOS mostra a própria barra azul de localização no topo da tela enquanto o Haven usa sua localização.';

  @override
  String get locationDisclosureTitle => 'Compartilhar sua localização';

  @override
  String get locationDisclosureWhy =>
      'O Haven mostra sua localização em tempo real para as pessoas dos círculos que você escolher e mostra a localização delas para você no mapa. Para isso, o Haven precisa de permissão para usar a localização precisa do seu dispositivo.';

  @override
  String get locationDisclosureHow =>
      'Sua localização é criptografada de ponta a ponta no seu dispositivo, então só os membros dos círculos que você escolher conseguem lê-la — o Haven, não. O Haven não tem servidores próprios: suas atualizações criptografadas passam por relays independentes mantidos por outras pessoas. Esses relays veem seu endereço de rede, mas nunca onde você está. Para desenhar o mapa, o Haven pede ao Stadia Maps as áreas ao redor de você e do seu círculo, então o Stadia Maps fica sabendo mais ou menos onde é isso, mas nunca seu nome, sua chave ou quem está nos seus círculos. O Stadia Maps afirma que não vende nem troca informações pessoais, que não instala cookies no seu dispositivo e que guarda os registros do servidor por cerca de duas semanas — é a política dele, que o Haven não tem como fazer cumprir.';

  @override
  String get locationDisclosureSharing =>
      'Enquanto o Haven está aberto e você faz parte de um círculo, sua localização é enviada automaticamente a cada poucos minutos. Não há como pausar. Para parar de compartilhar com um círculo, saia dele.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'Este app usa dados de localização para permitir o compartilhamento com seus círculos mesmo quando o app está fechado ou não está em uso.';

  @override
  String get locationDisclosureBackgroundIos =>
      'Este app usa dados de localização para permitir o compartilhamento com seus círculos mesmo quando o Haven está em segundo plano e você não está usando o app. Se o iOS fechar o Haven, o compartilhamento é interrompido até você abrir o app de novo — o Haven ainda pode acordar para buscar a localização dos seus círculos, mas nunca para enviar a sua.';

  @override
  String get locationDisclosureManage =>
      'Você pode desativar o compartilhamento em segundo plano a qualquer momento em Configurações → Localização.';

  @override
  String get locationDisclosureAgree => 'Concordo';

  @override
  String get locationDisclosureNotNow => 'Agora não';

  @override
  String get fgsNotificationSharing =>
      'O Haven está enviando e recebendo informações de localização';

  @override
  String get fgsNotificationPaused =>
      'O Haven está em pausa — abra o app para retomar o compartilhamento';

  @override
  String get fgsNotificationOpen => 'O Haven está aberto';

  @override
  String get fgsChannelName => 'Compartilhamento de localização';

  @override
  String get fgsChannelDescription =>
      'Mantém o Haven compartilhando sua localização criptografada em segundo plano.';

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
  String get aboutFooterLicense => 'Licenciado sob a MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Versão $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'O Haven não tem servidor próprio. Suas atualizações criptografadas passam por servidores independentes chamados relays, que não conseguem ler sua localização nem suas mensagens.';

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
  String get createCircleNoIdInQr => 'Nenhum ID válido encontrado no QR code';

  @override
  String get memberLookupNotFound =>
      'Nenhuma conta do Haven encontrada para este ID ainda. Se a pessoa acabou de configurar o Haven, tente de novo daqui a um minuto.';

  @override
  String get memberLookupIncomplete =>
      'Não foi possível concluir a verificação deste ID. Verifique sua conexão e tente de novo.';

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
          'Círculo \"$name\" criado. Convites enviados até agora: $sentString de $totalString. O Haven continua tentando enviar os demais enquanto o app estiver aberto, por até um dia.',
      many:
          'Círculo \"$name\" criado. Convites enviados até agora: $sentString de $totalString. O Haven continua tentando enviar os demais enquanto o app estiver aberto, por até um dia.',
      one:
          'Círculo \"$name\" criado. Convite enviado até agora: $sentString de $totalString. O Haven continua tentando enviá-lo enquanto o app estiver aberto, por até um dia.',
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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Você pode fazer parte de no máximo $limitString círculos ao mesmo tempo. Saia de um círculo para abrir espaço para um novo.';
  }

  @override
  String get circleCreateRefusedNoLocationRelay =>
      'Não é possível criar este círculo: todos os relays que o Haven usa para círculos estão, ou já estiveram, nas suas próprias listas de relays, por isso nenhum deles pode ser usado.';

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
          'Convites enviados para $circleName até agora: $sentString de $totalString. O Haven continua tentando enviar os demais enquanto o app estiver aberto, por até um dia.',
      many:
          'Convites enviados para $circleName até agora: $sentString de $totalString. O Haven continua tentando enviar os demais enquanto o app estiver aberto, por até um dia.',
      one:
          'Convite enviado para $circleName até agora: $sentString de $totalString. O Haven continua tentando enviá-lo enquanto o app estiver aberto, por até um dia.',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'O Haven não consegue enviar o convite para $circleName. Remova essa pessoa e adicione-a de novo.';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'O Haven não consegue convidar todas as pessoas que você escolheu, porque não conseguiu encontrar para onde enviar pelo menos um dos convites. Peça às pessoas que você escolheu para verificar se o app delas pode receber convites e, depois, tente de novo.';

  @override
  String get missedInvitationsShowWho => 'Ver quem';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Convites não enviados',
      many: 'Convites não enviados',
      one: 'Convite não enviado',
    );
    return '$_temp0';
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
  String get circleMemberNoRecentLocation => 'Sem localização recente';

  @override
  String get circleMemberRemoveTooltip => 'Remover do círculo';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return 'Remover $name?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'Essa pessoa deixa de conseguir ler qualquer coisa nova neste círculo assim que o restante dele se atualiza, normalmente em alguns minutos, e mais tempo para quem estava off-line na hora. O que ela já recebeu fica no telefone dela. Para desfazer isso, você precisaria convidá-la de novo.';

  @override
  String get circleMemberRemoveConfirm => 'Remover';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'Removendo $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name não está mais no círculo';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'Não foi possível remover $name. Nada mudou — verifique sua conexão e tente de novo.';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return 'Ainda removendo $name: aguardando os relays. Até que isso termine, nada é compartilhado com este círculo.';
  }

  @override
  String get circleMemberAdmin => 'Admin';

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
  String get pendingMemberNeedsUpdate => 'Precisa atualizar ou abrir o Haven';

  @override
  String get memberKeyPackageStale =>
      'O Haven não consegue convidar essa pessoa agora. Peça que ela abra o Haven. Depois, tente de novo.';

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
  String get memberPickerSectionRoster => 'Membros dos seus círculos';

  @override
  String get memberPickerTierRoster => 'Membro dos seus círculos';

  @override
  String get memberPickerNoMatches => 'Nenhum resultado nos seus círculos';

  @override
  String get memberPickerLoading =>
      'Carregando a lista de pessoas dos seus círculos';

  @override
  String get memberPickerDirectoryUnavailable =>
      'No momento, não foi possível carregar a lista de pessoas dos seus círculos';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Resultados: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'Este é o seu próprio ID';

  @override
  String get memberPickerReadPublicKey => 'Ler chave pública em voz alta';

  @override
  String get memberPickerSectionRecent => 'Recentemente nos seus círculos';

  @override
  String get memberPickerTierRecent => 'Recentemente nos seus círculos';

  @override
  String get memberPickerNicknameNote =>
      'Seu apelido para esta pessoa, não o nome público dela';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'Círculo: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'O Haven pediu a um relay — dois, no máximo — o perfil publicado desta pessoa. Cada relay consultado consegue ver que este dispositivo acabou de perguntar sobre esta chave, mas a consulta não leva assinatura criptográfica, então não fica ligada à sua identidade do Haven. Se o perfil tiver uma foto, o Haven baixa essa foto do servidor que esta pessoa escolheu, e esse servidor consegue ver o endereço de rede deste dispositivo.';

  @override
  String get memberPickerStrangerLookingUp => 'Consultando o perfil publicado…';

  @override
  String get memberPickerStrangerNotFound => 'Nenhum nome publicado encontrado';

  @override
  String memberPickerStrangerFoundAnnouncement(String name) {
    return 'Nome publicado: $name';
  }

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString a mais';
  }

  @override
  String get invitationCardHeading => 'Convite para um círculo';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Convite para entrar em um círculo, enviado por $inviter';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Convite enviado pelo identificador criptográfico $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Convite de: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'Seu apelido para esta pessoa, não o nome público dela';

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
  String invitationNeedsNewInviteError(String name) {
    return 'Este convite não pode mais ser usado. Peça a $name que convide você de novo. Talvez essa pessoa precise atualizar o Haven primeiro.';
  }

  @override
  String get rejoinDialogTitle => 'Entrar neste círculo de novo?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName convidou você para “$circleName”, que já está neste telefone. Isso pode acontecer se alguém tiver removido você do círculo e depois convidado você de volta. Entrar de novo substitui a cópia do círculo neste telefone. Recusar encerra este convite de vez; Cancelar guarda o convite para depois.';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'Você recebeu um convite para “$circleName”, que já está neste telefone. Isso pode acontecer se alguém tiver removido você do círculo e depois convidado você de volta. Entrar de novo substitui a cópia do círculo neste telefone. Recusar encerra este convite de vez; Cancelar guarda o convite para depois.';
  }

  @override
  String get rejoinDialogConfirm => 'Entrar de novo';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Você pode fazer parte de no máximo $limitString círculos ao mesmo tempo. Saia de um círculo e depois aceite este convite.';
  }

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
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · prazo de $expiry';
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
      other: 'cerca de $countString minutos',
      many: 'cerca de $countString de minutos',
      one: 'cerca de $countString minuto',
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
      many: '$countString de segundos',
      one: '$countString segundo',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. O Haven pede aos relays que descartem, depois de $expiry, as atualizações de localização que você envia para este círculo.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relays deste círculo';

  @override
  String get circleDetailsNoRelays => '(nenhum registrado)';

  @override
  String get circleDetailsRelaysNote =>
      'As atualizações criptografadas deste círculo passam por estes relays. Eles foram definidos quando o círculo foi criado e ainda não podem ser alterados no Haven; mudanças na sua lista de relays não os afetam.';

  @override
  String get circleDetailsAddMember => 'Adicionar membro';

  @override
  String get circleDetailsLeaveCircle => 'Sair do círculo';

  @override
  String get circleDetailsLeavingInProgress => 'Saindo do círculo…';

  @override
  String get leaveCircleDialogTitle => 'Sair do círculo';

  @override
  String get leaveCircleDialogBody =>
      'Sair deste círculo? Você deixará de enviar sua localização aos membros dele e de ver a localização deles. A última posição que você enviou fica nos telefones deles por até um dia. Isso não pode ser desfeito: você precisaria de um novo convite para voltar.';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'Este círculo foi encerrado, então nada mais é compartilhado com ele. Sair remove o círculo deste telefone.';

  @override
  String get leaveCircleDialogAdminNote =>
      'Você é admin deste círculo. Antes da sua saída, o Haven tenta tornar outro membro admin para que o círculo continue funcionando.';

  @override
  String get leaveCircleConfirm => 'Sair';

  @override
  String get leaveCircleIdentityUnavailable => 'Identidade indisponível';

  @override
  String get leaveCircleSuccess => 'Você saiu do círculo';

  @override
  String get leaveCircleError => 'Falha ao sair do círculo';

  @override
  String get legacyCircleRecreateCta => 'Recriar círculo';

  @override
  String get storageResetTitle => 'O Haven foi atualizado';

  @override
  String get storageResetKept =>
      'Sua identidade não mudou, e o perfil público que você já publicou continua como está.';

  @override
  String get storageResetLost =>
      'Para passar ao novo mecanismo de criptografia do Haven, os círculos criados antes desta atualização foram removidos. Recrie-os e convide os membros de novo. Os apelidos que você deu às pessoas antes desta atualização e qualquer alteração de perfil que até então ainda não tinha sido salva por completo também foram removidos.';

  @override
  String get storageResetRelays =>
      'Esta atualização redefiniu suas configurações de relays para os padrões do Haven. Elas não serão publicadas até você continuar ou voltar das Configurações de relays, então você pode adicionar seus próprios relays primeiro.';

  @override
  String get storageResetContinue => 'Continuar';

  @override
  String get storageResetOpenRelaySettings => 'Configurações de relays';

  @override
  String get storageResetAcknowledgeFailed =>
      'O Haven não conseguiu salvar sua resposta. Até que ela seja salva, o Haven não vai publicar suas configurações de relays nem sua chave de convite, então ninguém pode convidar você ainda. Tente de novo ou o Haven vai perguntar novamente na próxima vez que for aberto.';

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
      'Isso exclui sua identidade e todos os dados dos círculos deste telefone. Tudo o que já foi publicado com ela permanece onde está: seu nome e suas chaves nos relays que os têm, e sua foto no host de imagens que a armazena. Certifique-se de ter feito o backup da sua chave secreta caso queira recuperar sua identidade.';

  @override
  String get identityAdvancedDeleteConfirm => 'Excluir';

  @override
  String get identityAdvancedDeletedSnack => 'Identidade excluída';

  @override
  String get identityAdvancedDeleteError =>
      'Falha ao excluir a identidade. Tente de novo.';

  @override
  String get identityAdvancedDeletingProgress => 'Excluindo sua identidade…';

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
  String get reachabilityChecking => 'Preparando tudo para receber convites…';

  @override
  String get reachabilityReady => 'Tudo pronto para receber convites';

  @override
  String get reachabilityCantCheck =>
      'Não é possível verificar agora se outras pessoas podem convidar você';

  @override
  String get reachabilityNotReady =>
      'Outras pessoas ainda não podem convidar você';

  @override
  String get reachabilityNoRelays =>
      'Outras pessoas não podem convidar você até que você adicione um relay';

  @override
  String get reachabilityOpenRelaySettings => 'Configurações de relays';

  @override
  String get reachabilityAwaitingReset =>
      'Outras pessoas poderão convidar você assim que você continuar após o aviso sobre as configurações de relays';

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
  String get avatarPickerPhotoUpdatedAnnouncement => 'Foto atualizada.';

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
      'Este telefone está atrasado em relação ao resto dos seus círculos, então as posições que ele envia expiram cedo demais, e seus círculos podem perder algumas ou todas elas. Ative a data e hora automáticas nas configurações do sistema para corrigir isso.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'O relógio deste telefone já está certo. O Haven está compartilhando sua posição de novo.';

  @override
  String get clockSkewTitleDisagreement =>
      'Um relógio em um dos seus círculos está errado';

  @override
  String get clockSkewBodyDisagreement =>
      'O relógio deste telefone e o de outro membro estão com dois minutos ou mais de diferença. Se o errado for o deste telefone, as posições que ele envia podem expirar antes que alguém consiga vê-las. Ative a data e hora automáticas nas configurações do sistema para ter certeza de que não é o relógio deste telefone que está errado.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'O aviso sobre o relógio desapareceu.';

  @override
  String get sharingHealthTitleStopped =>
      'O compartilhamento de localização parou';

  @override
  String get sharingHealthTitleNotSending =>
      'Sua posição não está sendo compartilhada';

  @override
  String get sharingHealthTitleNotReceiving =>
      'Você não está recebendo localizações';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Sem atualizações há cerca de $countString minutos',
      many: 'Sem atualizações há cerca de $countString de minutos',
      one: 'Sem atualizações há cerca de 1 minuto',
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
      other: 'Sem atualizações há cerca de $countString horas',
      many: 'Sem atualizações há cerca de $countString de horas',
      one: 'Sem atualizações há cerca de 1 hora',
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
      other: 'Sem atualizações há cerca de $countString dias',
      many: 'Sem atualizações há cerca de $countString de dias',
      one: 'Sem atualizações há cerca de 1 dia',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Corrigir';

  @override
  String get sharingHealthRepairSent =>
      'Correção enviada. Os outros vão se atualizar assim que ela chegar no telefone deles.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Nada para corrigir por enquanto. O Haven vai continuar tentando.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'O compartilhamento de localização ainda não está funcionando.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'O compartilhamento de localização voltou a funcionar.';

  @override
  String get sharingHealthTitleQuarantined =>
      'O Haven não consegue abrir este círculo agora';

  @override
  String get sharingHealthBodyQuarantined =>
      'Algo deu errado ao carregar este círculo neste celular. O círculo continua aqui.';

  @override
  String get sharingHealthTitleDisbanded => 'Este círculo foi encerrado';

  @override
  String get sharingHealthBodyDisbanded =>
      'Uma pessoa admin encerrou este círculo, então nada mais é compartilhado com ele. Saia do círculo para removê-lo deste telefone.';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'Tenta carregar este círculo de novo';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'O Haven ainda não consegue abrir este círculo.';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'Este círculo parou de funcionar neste telefone';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Neste telefone, o Haven não consegue mais enviar nem receber atualizações neste círculo. Peça a uma pessoa admin deste círculo para remover e adicionar você de novo. Se ninguém puder, crie um novo círculo com as mesmas pessoas.';

  @override
  String get sharingHealthTitleStalled =>
      'O Haven não consegue ler as atualizações deste círculo';

  @override
  String get sharingHealthBodyStalled =>
      'Parece que este telefone deixou de receber uma alteração do círculo e não conseguiu encontrá-la nos relays. Peça a uma pessoa admin deste círculo para remover e adicionar você de novo. Se ninguém puder, crie um novo círculo com as mesmas pessoas.';

  @override
  String get sharingHealthTitlePaused => 'O Haven pausou este círculo';

  @override
  String get sharingHealthBodyCollision =>
      'O Haven encontrou um problema com este círculo neste telefone e parou de compartilhar com ele para manter sua localização privada. Sair do círculo é a única forma de resolver isso. Para voltar ao círculo, você vai precisar de um novo convite.';

  @override
  String get sharingHealthBodyCannotCheck =>
      'O Haven não conseguiu verificar este círculo neste telefone, então pausou o compartilhamento com ele para manter sua localização privada. O Haven volta a verificar por conta própria.';

  @override
  String get sharingHealthTitleLeaving => 'Você está saindo deste círculo';

  @override
  String get sharingHealthBodyLeaving =>
      'Nada é compartilhado com este círculo enquanto o Haven termina de sair dele. Isso pode levar cerca de um dia. O círculo desaparece deste telefone quando isso terminar.';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'Uma remoção que você pediu não foi feita, então o Haven pausou o compartilhamento da sua localização com este círculo para protegê-la de quem você tentou remover.';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'Uma remoção que você pediu não foi feita, então o Haven pausou o compartilhamento da sua localização com este círculo para protegê-la de quem você tentou remover. Abra a lista de membros para ver quem ainda está no círculo.';

  @override
  String get sharingHealthBodyDepartureDue =>
      'Alguém saiu deste círculo e a saída ainda não foi concluída. Até que isso aconteça, o Haven não compartilha sua localização com este círculo.';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'O compartilhamento em segundo plano está pausado para este círculo';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Os relays do círculo mudaram enquanto o Haven estava em segundo plano. O Haven termina a troca enquanto estiver aberto; até lá, nada é compartilhado com este círculo em segundo plano.';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'Uma alteração neste círculo está aguardando a confirmação de um relay. Até lá, o Haven não envia sua localização para este círculo nem mostra novas localizações vindas dele. O Haven continua tentando enquanto o app estiver aberto.';

  @override
  String get sharingHealthBodyAcknowledged =>
      'Um relay aceitou uma alteração neste círculo e o Haven está finalizando essa alteração. Até lá, as atualizações deste círculo ficam em espera.';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'Não foi possível salvar uma alteração neste círculo, então ela não foi enviada. O Haven resolve isso no mais tardar na próxima vez que for aberto; até lá, as atualizações deste círculo ficam em espera.';

  @override
  String get sharingHealthBodyStoredInput =>
      'Este telefone tem atualizações deste círculo que ainda não conseguiu processar. Até que isso aconteça, o Haven não compartilha sua localização com este círculo.';

  @override
  String get sharingHealthBodySessionHeld =>
      'O Haven ainda está encerrando a conexão anterior, então o compartilhamento de localização está pausado. O compartilhamento volta assim que isso terminar. Reiniciar o telefone sempre resolve isso.';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'Reconecta aos relays, tenta enviar sua localização de novo e pode dar novas chaves de criptografia a este círculo';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'O compartilhamento de localização precisa de atenção neste círculo. Abra os Detalhes do círculo para saber o motivo.';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return 'Algo sobre alterações recentes no círculo $circleName precisa da sua atenção. Abra os detalhes desse círculo para ler.';
  }

  @override
  String get circleDetailsAttentionTooltip =>
      'Detalhes do círculo, precisa de atenção';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, precisa de atenção';
  }

  @override
  String get changeNoticeHeading => 'Alterações neste círculo';

  @override
  String get changeNoteRemovalUndone =>
      'Uma alteração neste círculo não foi adiante. Se ela removia alguém, quem ela removia continua no círculo e pode ver o que é compartilhado com ele.';

  @override
  String get changeNoteChangeUndone =>
      'Uma alteração neste círculo não foi adiante, então nada mudou. Se a alteração era sua, refaça-a caso ainda queira.';

  @override
  String get changeNoteMayBeOutOfStep =>
      'Uma alteração neste círculo pode ter chegado aos outros sem que este telefone ficasse sabendo, então ele pode estar fora de sincronia com os outros.';

  @override
  String get changeNoteReinviteOwed =>
      'Alguém que você convidou está na lista de membros deste círculo, mas não consegue entrar, porque o Haven não consegue enviar o convite para essa pessoa. Remova a pessoa e adicione-a de novo.';

  @override
  String get changeNoteChangeUnrecorded =>
      'Não foi possível salvar uma alteração neste círculo, então ela não foi enviada.';

  @override
  String get changeNoteQueuedChangeDropped =>
      'Uma alteração que estava na fila deste círculo foi cancelada porque já não podia ser feita da forma pedida. Ela pode já ter sido feita de outra forma.';

  @override
  String get changeNoteQueuedChangesHeld =>
      'Algumas alterações neste círculo ainda estão esperando para serem feitas.';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'Uma remoção que você pediu neste círculo não foi feita. Quem você tentou remover pode ainda estar no círculo.';

  @override
  String get changeNoteChangeWithdrawn =>
      'A alteração de outro membro neste círculo substituiu uma das suas, então a sua não foi feita. Refaça-a caso ainda queira.';

  @override
  String get changeNoteWelcomeOwed =>
      'Um convite para este círculo ainda não foi enviado. O Haven continua tentando enviá-lo enquanto o app estiver aberto, por até um dia depois do convite. Se a pessoa não tiver entrado até lá, remova-a e adicione-a de novo.';

  @override
  String get changeNoteUnreadLocation =>
      'Algumas atualizações recentes enviadas a este círculo não puderam ser abertas neste telefone.';

  @override
  String get changeNoticeStillInCircleLabel => 'Ainda no círculo:';

  @override
  String get changeNoticeRemoveAgain => 'Remover de novo';

  @override
  String get changeNoticeReviewMembers => 'Revisar membros';

  @override
  String get changeNoticeKeepMembers => 'Manter no círculo';

  @override
  String get changeNoticeKeepConfirmTitle => 'Manter no círculo?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'O Haven não vai mais pausar o compartilhamento com este círculo por causa desta remoção. Quem você tentou remover e ainda está no círculo continua nele e pode ver sua localização sempre que o Haven a compartilhar com este círculo.';

  @override
  String get changeNoticeKeepConfirmAction => 'Manter';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Última localização há $countString minutos',
      many: 'Última localização há $countString de minutos',
      one: 'Última localização há 1 minuto',
    );
    return '$_temp0';
  }

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
  String get userLocationMarkerSemantics => 'Marcador da sua localização';

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
